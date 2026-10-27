package nse;

import flixel.FlxG;
import flixel.group.FlxTypedGroup;
import Conductor;
import ClientPrefs;
import Note;
import Conductor.BPMChangeEvent;
import Note.EventNote;
import Section.SwagSection;

/**
 * The streaming note engine.
 *
 * Psych 0.6.3 materialises the whole chart (`unspawnNotes` holds one Haxe object per note
 * *and* per sustain step), sorts it, then splices it away one note at a time: O(N) memory
 * and O(N^2) time. This class replaces that pipeline with
 *
 *     .nse chart  ->  NoteSource (O(1) memory, seekable)  ->  bounded live window (pooled)
 *
 * Only notes inside the spawn look-ahead window ever exist as sprites, and the sprites are
 * recycled, so per-frame work is O(live notes) no matter how long the chart is. Chart size
 * is limited by disk (2-3 bytes per note) or not limited at all (procedural charts).
 *
 * When a chart is denser than the GPU can draw, the live window caps the number of sprites
 * and reports `skipped` instead of stalling the game (`ClientPrefs.nseLiveCap`, 0 = no cap).
 */
class NseEngine
{
	/** the engine currently driving PlayState (used by the static section helpers) */
	public static var active:NseEngine = null;

	/** buckets: lane for player notes (mustPress), 4 + lane for opponent notes */
	static inline var BUCKETS:Int = 8;

	public var chart(default, null):NseChart;
	public var stream(default, null):NoteSource;
	public var pool(default, null):NotePool = new NotePool();

	/** interactive (head) notes currently alive, ordered by strum time */
	public var live(default, null):Array<Note> = [];

	/** maximum number of simultaneously alive head sprites, 0 = uncapped */
	public var liveCap:Int = 4096;
	/** collapse every sustain into 2 sprites (body + tail) instead of one per step */
	public var sustainSpans:Bool = true;
	/** mirror of PlayState.songSpeed, used to size sustain bodies */
	public var songSpeed:Float = 1;
	/** mirror of PlayState.noteKillOffset (350 / songSpeed) */
	public var killOffset:Float = 350;

	// ---- stats ----
	public var spawnedTotal:Float = 0;
	public var maxLive:Int = 0;
	public var skipped:Float = 0;
	public var reaped:Float = 0;
	public var spansTotal:Float = 0;

	/** live head notes per bucket (player 0-3, opponent 4-7), always in strum time order */
	var buckets:Array<Array<Note>> = [];

	// ---- sustain visuals: parallel arrays, no object per sustain ----
	var spanHit:Array<Bool> = [];
	var spanBody:Array<Note> = [];
	var spanTail:Array<Note> = [];
	var spanStart:Array<Float> = [];
	var spanEnd:Array<Float> = [];
	var spanLane:Array<Int> = [];
	var spanNextTick:Array<Float> = [];

	/** strum receptor Y per lane, refreshed by PlayState (used for hold trimming) */
	public var strumY:Array<Float> = [0, 0, 0, 0];

	public function new(chart:NseChart)
	{
		this.chart = chart;
		this.stream = chart.source;
		this.liveCap = ClientPrefs.nseLiveCap;
		this.sustainSpans = ClientPrefs.nseSustainSpans;
		var i:Int = 0;
		while (i < BUCKETS)
		{
			buckets.push([]);
			i++;
		}
		NseEngine.active = this;
	}

	public inline function sections():NseSectionTimeline
	{
		return chart.sections;
	}

	public function bpmChanges():Array<BPMChangeEvent>
	{
		return chart.bpmChanges;
	}

	public function events():Array<EventNote>
	{
		return chart.events;
	}

	public inline function noteCount():Float
	{
		return chart.noteCount;
	}

	public inline function liveCount():Int
	{
		return live.length;
	}

	public inline function spanCount():Int
	{
		return spanEnd.length;
	}

	public inline function laneBucket(lane:Int, opponent:Bool):Array<Note>
	{
		return buckets[(lane & 3) + (opponent ? 4 : 0)];
	}

	// ------------------------------------------------------------------ spawning
	/**
	 * Pulls every note whose strum time entered the look-ahead window into the live set.
	 *
	 * @return how many notes were spawned this call
	 */
	public function pump(songPos:Float, spawnTime:Float, speed:Float,
		group:FlxTypedGroup<Note>, onSpawn:Note->Void):Int
	{
		var lookAhead:Float = spawnTime;
		if (speed < 1 && speed > 0) lookAhead /= speed;

		var spawned:Int = 0;
		while (true)
		{
			var t:Float = stream.peekTime();
			if (t == Math.POSITIVE_INFINITY) break;
			if (t - songPos >= lookAhead) break;
			if (liveCap > 0 && live.length >= liveCap)
			{
				// denser than the sprite budget: keep the stream in sync with the song by
				// dropping the note instead of letting the window fall behind
				if (!stream.next()) break;
				skipped++;
				continue;
			}
			if (!stream.next()) break;
			spawnOne(stream.current(), group, onSpawn);
			spawned++;
		}
		if (live.length > maxLive) maxLive = live.length;
		return spawned;
	}

	function spawnOne(data:NseNoteData, group:FlxTypedGroup<Note>, onSpawn:Note->Void):Void
	{
		var strumTime:Float = data.t + ClientPrefs.noteOffset;
		var mustPress:Bool = data.mustPress();
		var lane:Int = data.lane & 3;
		var bucket:Array<Note> = buckets[lane + (mustPress ? 0 : 4)];

		var prev:Note = null;
		if (live.length > 0) prev = live[live.length - 1];

		var head:Note = pool.acquire(lane, 0, data.typeName, strumTime, mustPress, 0, prev);
		head.nseManaged = true;
		head.gfNote = (data.flags & Nse.NF_GFNOTE) != 0 || head.noteType == 'GF Sing';
		placeX(head, lane, mustPress);

		live.push(head);
		bucket.push(head);
		group.add(head);
		spawnedTotal++;

		if (data.span > 0 && sustainSpans) spawnSustain(data, strumTime, mustPress, head, group);
		else if (data.span > 0) head.sustainLength = data.span;

		if (onSpawn != null) onSpawn(head);
	}

	inline function placeX(note:Note, lane:Int, mustPress:Bool):Void
	{
		if (mustPress)
		{
			note.x += FlxG.width / 2;
		}
		else if (ClientPrefs.middleScroll)
		{
			note.x += 310;
			if (lane > 1) note.x += FlxG.width / 2 + 25;
		}
	}

	function spawnSustain(data:NseNoteData, strumTime:Float, mustPress:Bool, head:Note,
		group:FlxTypedGroup<Note>):Void
	{
		var spanEnd:Float = strumTime + data.span;
		var lane:Int = data.lane & 3;

		// one body sprite stretched over the whole hold instead of one sprite per step.
		// mustPress is kept so the sprite is positioned against the right strum group; the
		// note is ignoreNote, so no hit logic ever sees it.
		var body:Note = pool.acquire(lane, 1, null, strumTime, mustPress, data.span, head);
		body.nseManaged = true;
		body.gfNote = (data.flags & Nse.NF_GFNOTE) != 0 || head.gfNote;
		body.noAnimation = head.noAnimation;
		body.animSuffix = head.animSuffix;
		body.scale.y = body.poolScaleY * data.span * sustainScalePerMs();
		body.updateHitbox();
		placeX(body, lane, mustPress);
		group.add(body);

		var tail:Note = pool.acquire(lane, 2, null, spanEnd, mustPress, 0, body);
		tail.nseManaged = true;
		tail.gfNote = body.gfNote;
		placeX(tail, lane, mustPress);
		group.add(tail);

		spanHit.push(false);
		spanBody.push(body);
		spanTail.push(tail);
		spanStart.push(strumTime);
		spanEnd.push(spanEnd);
		spanLane.push(lane);
		spanNextTick.push(strumTime);
		spansTotal++;
	}

	/** vanilla: every sustain segment adds `1.05 * songSpeed / 100` to scale.y per ms */
	inline function sustainScalePerMs():Float
	{
		return 1.05 * (songSpeed <= 0 ? 1 : songSpeed) / 100;
	}

	// ------------------------------------------------------------------ hit helpers
	/**
	 * Player notes in `lane` that the player could hit right now, in strum time order.
	 * `out` is cleared and reused (no allocation in the common case).
	 */
	public function collectHittable(lane:Int, out:Array<Note>):Void
	{
		out.resize(0);
		var bucket:Array<Note> = buckets[lane & 3];
		var i:Int = 0;
		var len:Int = bucket.length;
		if (len > 32) len = 32;
		while (i < len)
		{
			var note:Note = bucket[i];
			i++;
			if (note.wasGoodHit || note.tooLate || note.blockHit || note.isSustainNote) continue;
			if (!note.canBeHit) continue;
			out.push(note);
		}
	}

	/** true when any player note is hittable right now (drives ghost-tap misses) */
	public function hasHittable():Bool
	{
		var lane:Int = 0;
		while (lane < 4)
		{
			var bucket:Array<Note> = buckets[lane];
			var i:Int = 0;
			var len:Int = bucket.length;
			if (len > 8) len = 8; // the front of a bucket is always the most relevant note
			while (i < len)
			{
				var note:Note = bucket[i];
				i++;
				if (note.wasGoodHit || note.tooLate || note.blockHit || note.isSustainNote) continue;
				if (note.canBeHit) return true;
			}
			lane++;
		}
		return false;
	}

	/**
	 * Called by PlayState when a head note is hit by the player; the following sustain
	 * starts awarding hold ticks.
	 */
	public function onHeadHit(head:Note):Void
	{
		var i:Int = 0;
		var len:Int = spanBody.length;
		while (i < len)
		{
			// the body sprite outlives the head (heads are recycled the moment they are hit),
			// so the span is identified through body.prevNote instead of holding the head
			var body:Note = spanBody[i];
			if (!spanHit[i] && body != null && body.prevNote == head
				&& spanLane[i] == (head.noteData & 3) && Math.abs(spanStart[i] - head.strumTime) < 1)
			{
				spanHit[i] = true;
				spanNextTick[i] = head.strumTime;
				return;
			}
			i++;
		}
	}

	/**
	 * Emits at most one "hold tick" per step per active span while its lane is held.
	 *
	 * Vanilla spawns one sprite per sustain step and feeds each of them through
	 * goodNoteHit(); a single stretched sprite means the engine has to generate the same
	 * health / vocal / animation refresh events itself.
	 */
	public function updateHolds(held:Array<Bool>, blocked:Array<Bool>, songPos:Float, stepMs:Float, onTick:Note->Int->Void):Void
	{
		var i:Int = 0;
		var len:Int = spanBody.length;
		while (i < len)
		{
			var lane:Int = spanLane[i];
			var body:Note = spanBody[i];
			if (spanHit[i] && body != null && held[lane] && (blocked == null || blocked[lane] != true)
				&& songPos < spanEnd[i] && songPos >= spanNextTick[i])
			{
				spanNextTick[i] = songPos + (stepMs > 0 ? stepMs : 100);
				if (onTick != null) onTick(body, lane);
			}
			i++;
		}
	}

	/** opponent holds: keep the character's sing animation alive without restarting it */
	public function updateOpponentHolds(songPos:Float, stepMs:Float, onTick:Note->Int->Void):Void
	{
		var i:Int = 0;
		var len:Int = spanBody.length;
		while (i < len)
		{
			var body:Note = spanBody[i];
			if (body != null && !body.mustPress && songPos >= spanStart[i] && songPos < spanEnd[i]
				&& songPos >= spanNextTick[i])
			{
				spanNextTick[i] = songPos + (stepMs > 0 ? stepMs : 100);
				if (onTick != null) onTick(body, spanLane[i]);
			}
			i++;
		}
	}

	// ------------------------------------------------------------------ per frame
	/**
	 * Reaps finished sustain sprites and trims hold bodies at the strum line.
	 * PlayState calls this once per frame, after the vanilla note movement pass.
	 */
	public function postUpdate(songPos:Float, group:FlxTypedGroup<Note>):Void
	{
		var i:Int = spanEnd.length - 1;
		while (i >= 0)
		{
			if (songPos > spanEnd[i] + killOffset)
			{
				var body:Note = spanBody[i];
				var tail:Note = spanTail[i];
				removeSpan(i);
				despawn(body, group);
				despawn(tail, group);
				reaped++;
			}
			i--;
		}

		// trim hold bodies that scrolled past the strum line (vanilla's sustainReduce visual)
		var downScroll:Bool = ClientPrefs.downScroll;
		i = 0;
		var len:Int = spanBody.length;
		while (i < len)
		{
			var body:Note = spanBody[i];
			if (body != null && body.exists)
			{
				var laneIdx:Int = spanLane[i] & 3;
				var center:Float = strumY[laneIdx] + Note.swagWidth / 2;
				var scaleY:Float = body.scale.y == 0 ? 1.0 : body.scale.y;
				var rect:FlxRect = body.clipRect;
				if (downScroll)
				{
					if (body.y - body.offset.y * body.scale.y + body.height >= center)
					{
						var rectH:Float = (center - body.y) / scaleY;
						if (rectH < 0) rectH = 0;
						if (rect == null)
						{
							rect = new FlxRect(0, 0, body.frameWidth, body.frameHeight);
							body.clipRect = rect;
						}
						if (rect.height != rectH)
						{
							rect.height = rectH;
							rect.y = body.frameHeight - rectH;
						}
					}
				}
				else if (body.y + body.offset.y * body.scale.y <= center)
				{
					var rectY:Float = (center - body.y) / scaleY;
					if (rectY < 0) rectY = 0;
					if (rect == null)
					{
						rect = new FlxRect(0, 0, body.frameWidth, body.frameHeight);
						body.clipRect = rect;
					}
					if (rect.y != rectY)
					{
						rect.y = rectY;
						rect.height = body.frameHeight - rectY;
					}
				}
			}
			i++;
		}
	}

	function removeSpan(i:Int):Void
	{
		var last:Int = spanEnd.length - 1;
		spanHit[i] = spanHit[last];
		spanBody[i] = spanBody[last];
		spanTail[i] = spanTail[last];
		spanStart[i] = spanStart[last];
		spanEnd[i] = spanEnd[last];
		spanLane[i] = spanLane[last];
		spanNextTick[i] = spanNextTick[last];
		spanHit.pop();
		spanBody.pop();
		spanTail.pop();
		spanStart.pop();
		spanEnd.pop();
		spanLane.pop();
		spanNextTick.pop();
	}

	function unlinkBucket(note:Note):Void
	{
		var bucket:Array<Note> = buckets[(note.noteData & 3) + (note.mustPress ? 0 : 4)];
		var i:Int = 0;
		var len:Int = bucket.length;
		while (i < len)
		{
			if (bucket[i] == note)
			{
				bucket.splice(i, 1);
				return;
			}
			i++;
		}
	}

	/** removes a note from the group + live set and returns it to the pool */
	public function despawn(note:Note, group:FlxTypedGroup<Note>):Void
	{
		if (note == null) return;

		if (!note.isSustainNote)
		{
			var si:Int = 0;
			var slen:Int = spanBody.length;
			while (si < slen)
			{
				var body:Note = spanBody[si];
				if (body != null && body.prevNote == note) body.prevNote = body;
				si++;
			}
			unlinkBucket(note);
			var i:Int = live.length - 1;
			while (i >= 0)
			{
				if (live[i] == note)
				{
					live.splice(i, 1);
					break;
				}
				i--;
			}
		}

		if (group != null && note.exists) group.remove(note, true);
		pool.release(note);
	}

	/** drops every note with strumTime - 350 < time, like PlayState.clearNotesBefore */
	public function clearBefore(time:Float, group:FlxTypedGroup<Note>):Void
	{
		stream.seek(time);

		var i:Int = live.length - 1;
		while (i >= 0)
		{
			var note:Note = live[i];
			if (note != null && note.strumTime - 350 < time) despawn(note, group);
			i--;
		}

		i = spanEnd.length - 1;
		while (i >= 0)
		{
			if (spanEnd[i] - 350 < time)
			{
				var body:Note = spanBody[i];
				var tail:Note = spanTail[i];
				removeSpan(i);
				despawn(body, group);
				despawn(tail, group);
			}
			i--;
		}
	}

	/** notes that were never played (used by the anti-cheat check at the end of a song) */
	public function unplayedEstimate():Float
	{
		var remaining:Float = stream.totalNotes() - stream.streamedNotes();
		if (remaining < 0) remaining = 0;
		return remaining;
	}

	public function onSongSpeedChanged(speed:Float):Void
	{
		songSpeed = speed;
		killOffset = 350 / (speed <= 0 ? 1 : speed);
		var i:Int = 0;
		var len:Int = spanBody.length;
		while (i < len)
		{
			var body:Note = spanBody[i];
			if (body != null)
			{
				body.scale.y = body.poolScaleY * (spanEnd[i] - spanStart[i]) * sustainScalePerMs();
				body.updateHitbox();
			}
			i++;
		}
	}

	public function reset(group:FlxTypedGroup<Note>):Void
	{
		var i:Int = live.length - 1;
		while (i >= 0)
		{
			despawn(live[i], group);
			i--;
		}
		live = [];

		i = spanEnd.length - 1;
		while (i >= 0)
		{
			despawn(spanBody[i], group);
			despawn(spanTail[i], group);
			i--;
		}
		var lane:Int = 0;
		while (lane < BUCKETS)
		{
			buckets[lane].resize(0);
			lane++;
		}
		spanHit = [];
		spanBody = [];
		spanTail = [];
		spanStart = [];
		spanEnd = [];
		spanLane = [];
		spanNextTick = [];
		stream.reset();
		spawnedTotal = 0;
		skipped = 0;
		reaped = 0;
		spansTotal = 0;
		maxLive = 0;
	}

	public function destroy():Void
	{
		if (NseEngine.active == this) NseEngine.active = null;
		pool.clear();
		chart.close();
	}

	public function stats():String
	{
		return 'NSE ' + Std.string(stream.streamedNotes()) + '/' + Std.string(chart.noteCount)
			+ ' notes, live ' + live.length + ' (peak ' + maxLive + '), spans ' + spanEnd.length
			+ ', skipped ' + skipped + ', ' + pool.stats();
	}

	// ------------------------------------------------------------------ virtual sections
	public static function sectionCount():Int
	{
		return active == null ? 0 : active.chart.sections.count;
	}

	public static function sectionBeats(section:Int):Float
	{
		return active == null ? 4 : active.chart.sections.beatsOf(section);
	}

	public static function sectionView(section:Int):SwagSection
	{
		return active == null ? null : active.chart.sections.section(section);
	}

	public static function bpmChangeList():Array<BPMChangeEvent>
	{
		return active == null ? null : active.chart.bpmChanges;
	}

	/** decides whether a chart should be streamed instead of materialised */
	public static function shouldStream(jsonBytes:Float, noteEstimate:Float):Bool
	{
		if (ClientPrefs.nseMode == ClientPrefs.NSE_OFF) return false;
		if (ClientPrefs.nseMode == ClientPrefs.NSE_ALWAYS) return true;
		return noteEstimate >= ClientPrefs.nseThresholdNotes || jsonBytes >= ClientPrefs.nseThresholdBytes;
	}
}
