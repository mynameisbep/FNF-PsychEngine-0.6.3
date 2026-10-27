package nse;

import Song.SwagSong;
import Section.SwagSection;
import haxe.io.Bytes;

/**
 * Offline / load-time compiler: Psych `SwagSong` (parsed chart JSON) -> .nse container.
 *
 * This is a straight port of `ChartBuilder` in tools/nse/nse_ref.py, which is the
 * executable specification of the format and is covered by tests. Both produce
 * byte-identical output for the same input chart (see tools/nse/test_nse.py).
 *
 * The compiler is intentionally a single pass over the sections plus a sort, so compiling
 * a chart is far cheaper than the classic loader (which builds a Haxe object per note).
 */
class ChartCompiler
{
	public static inline var NOTE_TYPE_LIST:Array<String> = ['', 'Alt Animation', 'Hey!', 'Hurt Note', 'GF Sing', 'No Animation'];

	var times:Array<Float> = [];
	var lanes:Array<Int> = [];
	var flags:Array<Int> = [];
	var spans:Array<Float> = [];
	var typeIdx:Array<Int> = [];

	var strings:Array<String> = [];
	var stringMap:Map<String, Int> = new Map<String, Int>();

	var sections:NseSectionTimeline = new NseSectionTimeline();
	var bpmChanges:Array<Float> = [];    // triples: songTime, bpm, stepTime
	var events:Array<Float> = [];        // quadruples: time, nameIdx, value1Idx, value2Idx

	var bpm:Float = 120;
	var speed:Float = 1;
	var lanesCount:Int = 4;

	public function new() {}

	inline function typeId(name:String):Int
	{
		if (name == null || name.length == 0) return -1;
		var existing:Null<Int> = stringMap.get(name);
		if (existing != null) return existing;
		var id:Int = strings.length;
		stringMap.set(name, id);
		strings.push(name);
		return id;
	}

	inline function eventId(name:String):Int
	{
		if (name == null) name = '';
		var existing:Null<Int> = stringMap.get(name);
		if (existing != null) return existing;
		var id:Int = strings.length;
		stringMap.set(name, id);
		strings.push(name);
		return id;
	}

	function addNote(t:Float, data:Int, sustain:Float, typeName:String, mustPress:Bool, gfNote:Bool):Void
	{
		var lane:Int = data % 4;
		if (lane < 0) lane = 0;
		var f:Int = 0;
		if (mustPress) f |= Nse.NF_MUSTPRESS;
		if (sustain > 0) f |= Nse.NF_SUSTAIN;
		if (gfNote) f |= Nse.NF_GFNOTE;
		var ti:Int = typeId(typeName);
		if (ti >= 0) f |= Nse.NF_HASTYPE;
		if (typeName == 'Hurt Note') f |= Nse.NF_LOWPRIORITY | Nse.NF_HITCAUSESMISS;
		if (typeName == 'No Animation') f |= Nse.NF_NOANIM;

		times.push(t);
		lanes.push(lane);
		flags.push(f);
		spans.push(sustain > 0 ? sustain : 0);
		typeIdx.push(ti);
	}

	/**
	 * Compiles a chart. `noteTypeList` comes from ChartingState (index based note types in
	 * week 7 charts); pass null to fall back to the engine default list.
	 */
	public function compile(song:SwagSong, ?typeList:Array<String>):NseChart
	{
		bpm = song.bpm > 0 ? song.bpm : 120;
		speed = song.speed > 0 ? song.speed : 1;
		var types:Array<String> = typeList == null ? NOTE_TYPE_LIST : typeList;

		var secs:Array<SwagSection> = song.notes;
		var curBpm:Float = bpm;
		var stepCrochet:Float = (60000.0 / curBpm) / 4.0;
		var sectionTime:Float = 0;
		var totalSteps:Int = 0;

		var s:Int = 0;
		var secCount:Int = secs == null ? 0 : secs.length;
		while (s < secCount)
		{
			var sec:SwagSection = secs[s];
			if (sec == null)
			{
				s++;
				continue;
			}
			var beats:Float = sec.sectionBeats > 0 ? sec.sectionBeats : 4;
			var sectionBpm:Float = sec.bpm;
			var changeBpm:Bool = sec.changeBPM && sectionBpm > 0 && sectionBpm != curBpm;

			var sf:Int = 0;
			if (sec.mustHitSection) sf |= Nse.SF_MUSTHIT;
			if (sec.gfSection) sf |= Nse.SF_GF;
			if (sec.altAnim) sf |= Nse.SF_ALT;
			if (changeBpm) sf |= Nse.SF_CHBPM;
			sections.push(1, beats, sf, changeBpm ? sectionBpm : curBpm);

			if (changeBpm)
			{
				bpmChanges.push(sectionTime);
				bpmChanges.push(sectionBpm);
				bpmChanges.push(totalSteps);
				curBpm = sectionBpm;
				stepCrochet = (60000.0 / curBpm) / 4.0;
			}

			var mustHit:Bool = sec.mustHitSection;
			var gfSec:Bool = sec.gfSection;
			var list:Array<Dynamic> = sec.sectionNotes;
			if (list != null)
			{
				var i:Int = 0;
				var len:Int = list.length;
				while (i < len)
				{
					var raw:Dynamic = list[i];
					i++;
					if (raw == null) continue;
					var arr:Array<Dynamic> = cast raw;
					if (arr.length < 2) continue;
					if (arr[0] == null || arr[1] == null) continue;
					var t:Float = cast arr[0];
					var data:Int = Std.int(cast arr[1]);
					if (data < 0)
					{
						// legacy event note: [time, [[name, value1, value2], ...]]
						if (arr.length > 2)
						{
							var subs:Dynamic = arr[2];
							if (Std.isOfType(subs, Array))
							{
								var subArr:Array<Dynamic> = cast subs;
								var k:Int = 0;
								while (k < subArr.length)
								{
									var sub:Array<Dynamic> = cast subArr[k];
									if (sub != null && sub.length > 0)
									{
										events.push(t);
										events.push(eventId(Std.string(sub[0])));
										events.push(eventId(sub.length > 1 ? Std.string(sub[1]) : ''));
										events.push(eventId(sub.length > 2 ? Std.string(sub[2]) : ''));
									}
									k++;
								}
							}
						}
						continue;
					}
					var sustain:Float = 0;
					if (arr.length > 2 && arr[2] != null) sustain = cast arr[2];
					if (!(sustain > 0)) sustain = 0;   // also catches NaN
					var typeName:String = '';
					if (arr.length > 3)
					{
						var rawType:Dynamic = arr[3];
						if (Std.isOfType(rawType, String))
						{
							typeName = cast rawType;
						}
						else if (rawType != null)
						{
							var ti:Int = Std.int(cast rawType);
							if (ti >= 0 && ti < types.length) typeName = types[ti];
						}
					}
					var mustPress:Bool = mustHit;
					if (data > 3) mustPress = !mustHit;
					addNote(t, data, sustain, typeName, mustPress, gfSec && data < 4);
				}
			}

			var deltaSteps:Int = Math.round(beats * 4);
			totalSteps += deltaSteps;
			sectionTime += deltaSteps * stepCrochet;
			s++;
		}

		// song events (0.6.3 format: [time, [[name, v1, v2], ...]])
		var evs:Array<Dynamic> = song.events;
		if (evs != null)
		{
			var i:Int = 0;
			while (i < evs.length)
			{
				var ev:Array<Dynamic> = cast evs[i];
				i++;
				if (ev == null || ev.length < 2 || ev[0] == null) continue;
				var t:Float = cast ev[0];
				var subs:Array<Dynamic> = cast ev[1];
				if (subs == null) continue;
				var k:Int = 0;
				while (k < subs.length)
				{
					var sub:Array<Dynamic> = cast subs[k];
					k++;
					if (sub == null || sub.length == 0) continue;
					events.push(t);
					events.push(eventId(Std.string(sub[0])));
					events.push(eventId(sub.length > 1 ? Std.string(sub[1]) : ''));
					events.push(eventId(sub.length > 2 ? Std.string(sub[2]) : ''));
				}
			}
		}

		return toChart();
	}

	function sortNotes():Void
	{
		var order:Array<Int> = [];
		var n:Int = times.length;
		order.resize(n);
		var i:Int = 0;
		while (i < n)
		{
			order[i] = i;
			i++;
		}
		// Array.sort is stable enough for our needs: ties on time are broken by lane
		order.sort(function(a:Int, b:Int):Int {
			var ta:Float = times[a];
			var tb:Float = times[b];
			if (ta < tb) return -1;
			if (ta > tb) return 1;
			var la:Int = lanes[a];
			var lb:Int = lanes[b];
			if (la < lb) return -1;
			if (la > lb) return 1;
			return 0;
		});

		var t2:Array<Float> = [];
		var l2:Array<Int> = [];
		var f2:Array<Int> = [];
		var s2:Array<Float> = [];
		var ty2:Array<Int> = [];
		i = 0;
		while (i < n)
		{
			var idx:Int = order[i];
			t2.push(times[idx]);
			l2.push(lanes[idx]);
			f2.push(flags[idx]);
			s2.push(spans[idx]);
			ty2.push(typeIdx[idx]);
			i++;
		}
		times = t2;
		lanes = l2;
		flags = f2;
		spans = s2;
		typeIdx = ty2;
	}

	function toChart():NseChart
	{
		sortNotes();
		sections.finalize();
		var bytes:Bytes = serialise();
		return NseChart.fromBytes(bytes, 'compiled');
	}

	/** serialises everything collected so far into a .nse container */
	public function serialise():Bytes
	{
		sections.finalize();
		var n:Int = times.length;

		// --- chunk the notes, keeping a directory of (count, byteLength)
		var chunkCnt:Array<Int> = [];
		var chunkLen:Array<Int> = [];
		var w:NseWriter = new NseWriter();
		var i:Int = 0;
		while (i < n)
		{
			var start:Int = w.length();
			var count:Int = 0;
			var base:Int = Std.int(times[i]);
			var lastDt:Int = -1;
			w.varint(base);
			while (i < n && count < Nse.CHUNK_CAPACITY)
			{
				var t:Int = Std.int(times[i]);
				var dt:Int = t - base;
				w.u8(lanes[i]);
				var f:Int = flags[i];
				if (dt == lastDt) f |= Nse.NF_DTREPEAT;
				w.u8(f);
				if (dt != lastDt)
				{
					w.varint(dt < 0 ? 0 : dt);
					lastDt = dt;
				}
				if ((f & Nse.NF_SUSTAIN) != 0) w.varint(Math.round(spans[i]));
				if ((f & Nse.NF_HASTYPE) != 0) w.varint(typeIdx[i]);
				base = t;
				count++;
				i++;
			}
			chunkCnt.push(count);
			chunkLen.push(w.length() - start);
		}
		var payload:Bytes = w.getBytes();

		var duration:Float = 0;
		if (n > 0)
		{
			duration = times[n - 1] + spans[n - 1];
		}

		var out:NseWriter = new NseWriter();
		out.u8(Nse.MAGIC0);
		out.u8(Nse.MAGIC1);
		out.u8(Nse.MAGIC2);
		out.u8(Nse.MAGIC3);
		out.u8(Nse.VERSION & 0xFF);
		out.u8((Nse.VERSION >> 8) & 0xFF);
		var headerFlags:Int = 0;
		if (strings.length > 0) headerFlags |= Nse.F_TYPES;
		if (events.length > 0) headerFlags |= Nse.F_EVENTS;
		out.u8(headerFlags & 0xFF);
		out.u8((headerFlags >> 8) & 0xFF);
		out.u8(lanesCount);
		out.u8(1); // fidelity: sustain spans
		out.varint(Math.round(bpm * 1000));
		out.varint(Math.round(speed * 1000));
		out.varintFloat(n);
		out.varint(Nse.CHUNK_CAPACITY);
		out.varint(sections.count);
		out.varint(Math.round(duration));

		// string table
		out.varint(strings.length);
		i = 0;
		while (i < strings.length)
		{
			out.string(strings[i]);
			i++;
		}

		// section runs
		var runLen:Array<Int> = sections.exportRuns();
		out.varint(runLen.length);
		i = 0;
		while (i < runLen.length)
		{
			out.varint(runLen[i]);
			out.varint(Math.round(sections.exportBeats()[i] * 1000));
			var sf:Int = sections.exportFlags()[i];
			out.u8(sf);
			if ((sf & Nse.SF_CHBPM) != 0) out.varint(Math.round(sections.exportBpms()[i] * 1000));
			i++;
		}

		// bpm changes (time, bpm, stepTime)
		out.varint(Std.int(bpmChanges.length / 3));
		var prevTime:Float = 0;
		i = 0;
		while (i < bpmChanges.length)
		{
			var t:Float = bpmChanges[i];
			out.varint(Math.round(t - prevTime));
			out.varint(Math.round(bpmChanges[i + 1] * 1000));
			out.varint(Std.int(bpmChanges[i + 2]));
			prevTime = t;
			i += 3;
		}

		// chunk directory
		out.varint(chunkLen.length);
		i = 0;
		while (i < chunkLen.length)
		{
			out.varint(chunkCnt[i]);
			out.varint(chunkLen[i]);
			i++;
		}

		// events
		out.varint(Std.int(events.length / 4));
		prevTime = 0;
		i = 0;
		while (i < events.length)
		{
			var t:Float = events[i];
			out.varint(Math.round(t - prevTime));
			out.varint(Std.int(events[i + 1]));
			out.varint(Std.int(events[i + 2]));
			out.varint(Std.int(events[i + 3]));
			prevTime = t;
			i += 4;
		}

		out.raw(payload);
		return out.getBytes();
	}

	public function noteCount():Int
	{
		return times.length;
	}
}
