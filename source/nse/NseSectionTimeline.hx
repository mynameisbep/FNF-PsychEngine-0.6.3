package nse;

import Section.SwagSection;

/**
 * Run-length encoded section metadata.
 *
 * A chart of 10^9 notes at 8 notes per step has ~31 million sections; materialising one
 * SwagSection object per section would cost gigabytes. Charts almost never change their
 * section metadata, so we store `runs` of identical sections instead:
 *
 *   [ {len: 4096, beats: 4, flags: MUSTHIT}, {len: 64, beats: 4, flags: 0, bpm: 180}, ... ]
 *
 * Lookup is O(1) for the monotonically increasing queries the game performs every section
 * (the run cursor is cached), and O(log runs) for random access (practice mode seeks).
 */
class NseSectionTimeline
{
	public var count(default, null):Int = 0;

	var runLen:Array<Int> = [];
	var runBeats:Array<Float> = [];
	var runFlags:Array<Int> = [];
	var runBpm:Array<Float> = [];
	var starts:Array<Int> = [];
	var cursor:Int = -1;

	/** shared view returned by section() so callers never allocate */
	var view:SwagSection = {
		sectionNotes: [],
		sectionBeats: 4,
		typeOfSection: 0,
		mustHitSection: true,
		gfSection: false,
		bpm: 0,
		changeBPM: false,
		altAnim: false
	};

	public function new() {}

	public inline function runs():Int
	{
		return runLen.length;
	}

	public function push(runLength:Int, beats:Float, flags:Int, bpm:Float):Void
	{
		if (runLength <= 0) return;
		var n:Int = runLen.length;
		if (n > 0 && runBeats[n - 1] == beats && runFlags[n - 1] == flags
			&& ((flags & Nse.SF_CHBPM) == 0 || runBpm[n - 1] == bpm))
		{
			runLen[n - 1] += runLength;
		}
		else
		{
			runLen.push(runLength);
			runBeats.push(beats);
			runFlags.push(flags);
			runBpm.push(bpm);
		}
		count += runLength;
	}

	public function finalize():Void
	{
		starts = [];
		var s:Int = 0;
		var i:Int = 0;
		while (i < runLen.length)
		{
			starts.push(s);
			s += runLen[i];
			i++;
		}
		cursor = -1;
	}

	public function indexOf(section:Int):Int
	{
		if (runLen.length == 0) return -1;
		if (section < 0) section = 0;
		if (section >= count) section = count - 1;

		var c:Int = cursor;
		if (c >= 0 && c < runLen.length)
		{
			var start:Int = starts[c];
			if (section >= start && section < start + runLen[c]) return c;
			if (c + 1 < runLen.length && section >= starts[c + 1] && section < starts[c + 1] + runLen[c + 1])
			{
				cursor = c + 1;
				return c + 1;
			}
		}

		var lo:Int = 0;
		var hi:Int = runLen.length - 1;
		while (lo < hi)
		{
			var mid:Int = (lo + hi + 1) >> 1;
			if (starts[mid] <= section) lo = mid;
			else hi = mid - 1;
		}
		cursor = lo;
		return lo;
	}

	public function beatsOf(section:Int):Float
	{
		var i:Int = indexOf(section);
		return i < 0 ? 4 : runBeats[i];
	}

	public function flagsOf(section:Int):Int
	{
		var i:Int = indexOf(section);
		return i < 0 ? Nse.SF_MUSTHIT : runFlags[i];
	}

	public function bpmOf(section:Int):Float
	{
		var i:Int = indexOf(section);
		return i < 0 ? 0 : runBpm[i];
	}

	public function mustHit(section:Int):Bool
	{
		return (flagsOf(section) & Nse.SF_MUSTHIT) != 0;
	}

	public function isGfSection(section:Int):Bool
	{
		return (flagsOf(section) & Nse.SF_GF) != 0;
	}

	public function isAltAnim(section:Int):Bool
	{
		return (flagsOf(section) & Nse.SF_ALT) != 0;
	}

	public function changesBpm(section:Int):Bool
	{
		return (flagsOf(section) & Nse.SF_CHBPM) != 0;
	}

	/**
	 * Section lookup helper, so section changes and stale `SONG.notes[...]` accesses
	 * keep working when no physical section array exists.
	 */
	public function section(section:Int):SwagSection
	{
		var i:Int = indexOf(section);
		var flags:Int = i < 0 ? Nse.SF_MUSTHIT : runFlags[i];
		view.sectionBeats = i < 0 ? 4 : runBeats[i];
		view.mustHitSection = (flags & Nse.SF_MUSTHIT) != 0;
		view.gfSection = (flags & Nse.SF_GF) != 0;
		view.altAnim = (flags & Nse.SF_ALT) != 0;
		view.changeBPM = (flags & Nse.SF_CHBPM) != 0;
		view.bpm = i < 0 ? 0 : runBpm[i];
		return view;
	}

	public function exportRuns():Array<Int>
	{
		return runLen;
	}

	public function exportBeats():Array<Float>
	{
		return runBeats;
	}

	public function exportFlags():Array<Int>
	{
		return runFlags;
	}

	public function exportBpms():Array<Float>
	{
		return runBpm;
	}
}
