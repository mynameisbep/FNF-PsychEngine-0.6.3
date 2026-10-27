package nse;

import Conductor;
import ClientPrefs;
import Paths;
import SUtil;
import Conductor.BPMChangeEvent;
import Note.EventNote;
import Section.SwagSection;
import haxe.io.Bytes;

#if sys
import sys.FileSystem;
#end

/**
 * A loaded .nse chart: header + table of contents + a lazily created note stream.
 *
 * Loading a chart never touches the note payload, so opening a billion-note chart costs
 * the same as opening a thousand-note one: a few MiB of chunk directory and a few
 * microseconds of parsing.
 */
class NseChart
{
	/** how much of a file we are willing to read to locate the TOC (~40 billion notes) */
	public static inline var TOC_WINDOW:Int = 64 * 1024 * 1024;

	public var flags:Int = 0;
	public var lanes:Int = 4;
	public var fidelity:Int = 1;
	public var bpm:Float = 120;
	public var speed:Float = 1;
	public var noteCount:Float = 0;
	public var chunkCapacity:Int = Nse.CHUNK_CAPACITY;
	public var sectionCount:Int = 0;
	public var durationMs:Float = 0;

	public var typeNames:Array<String> = [];
	public var sections:NseSectionTimeline = new NseSectionTimeline();
	public var bpmChanges:Array<BPMChangeEvent> = [];
	public var events:Array<EventNote> = [];
	public var chunkCount(default, null):Int = 0;

	public var source(default, null):NoteSource = null;
	public var procSpec(default, null):ProcSpec = null;
	public var origin:String = '';

	var chunkOff:Array<Float> = [];
	var chunkLen:Array<Int> = [];
	var chunkCnt:Array<Int> = [];
	var payloadOffset:Int = 0;
	var filePath:String = null;
	var fileInput:Dynamic = null; // sys.io.FileInput when loaded from disk

	public function new() {}

	public function isProcedural():Bool
	{
		return (flags & Nse.F_PROC) != 0;
	}

	public static function fromBytes(bytes:Bytes, ?origin:String = 'memory'):NseChart
	{
		if (!Nse.isNse(bytes)) throw 'NSE: not a .nse chart (bad magic)';
		var chart:NseChart = new NseChart();
		chart.origin = origin;
		chart.filePath = null;

		var r:NseReader = new NseReader(bytes, 4);
		r.bounded = true;
		chart.readToc(r);
		if (r.truncated) throw 'NSE: truncated chart';
		chart.payloadOffset = r.pos;

		if (chart.isProcedural())
		{
			chart.procSpec = ProcSpec.parse(bytes, chart.payloadOffset);
			chart.source = new ProcNoteStream(chart.procSpec);
		}
		else
		{
			var end:Int = bytes.length;
			if ((chart.flags & Nse.F_CRC) != 0 && end - 4 > chart.payloadOffset) end -= 4;
			var payload:Bytes = bytes.sub(chart.payloadOffset, end - chart.payloadOffset);
			chart.source = new NseMemoryStream(payload, chart.chunkOff, chart.chunkLen, chart.chunkCnt,
				chart.chunkCapacity, chart.typeNames);
		}
		return chart;
	}

#if sys
	public static function fromFile(path:String):NseChart
	{
		var size:Float = sys.FileSystem.stat(path).size;
		var window:Int = Std.int(Math.min(size, TOC_WINDOW));
		if (window < 64) window = Std.int(Math.min(size, 64));

		var input = sys.io.File.read(path, false);
		var head:Bytes = input.read(window);

		var chart:NseChart = new NseChart();
		chart.origin = path;
		chart.filePath = path;

		var r:NseReader = new NseReader(head, 4);
		r.bounded = true;
		if (!Nse.isNse(head)) throw 'NSE: not a .nse chart (bad magic)';
		chart.readToc(r);
		if (r.truncated)
			throw 'NSE: chunk directory does not fit in the ' + Std.int(TOC_WINDOW / 1048576) + ' MiB TOC window';
		chart.payloadOffset = r.pos;

		if (chart.isProcedural())
		{
			chart.procSpec = ProcSpec.parse(head, chart.payloadOffset);
			chart.source = new ProcNoteStream(chart.procSpec);
			input.close();
		}
		else
		{
			chart.source = new NseFileStream(input, chart.payloadOffset, chart.chunkOff, chart.chunkLen,
				chart.chunkCnt, chart.chunkCapacity, chart.typeNames);
			chart.fileInput = input;
		}
		return chart;
	}
#end

	/**
	 * Locates the .nse sidecar that belongs to a chart folder, honouring mod overrides
	 * exactly like Paths.modFolders() does for JSON charts.
	 */
	#if sys
	public static function findSidecar(songName:String):String
	{
		var key:String = 'data/' + songName + '/' + songName + '.nse';
		#if MODS_ALLOWED
		var modPath:String = Paths.modFolders(key);
		if (FileSystem.exists(modPath)) return modPath;
		#end
		var base:String = SUtil.getPath() + Paths.getPreloadPath(key);
		if (FileSystem.exists(base)) return base;
		return null;
	}

	/** loads the sidecar for `songName`, or null when the chart has none */
	public static function loadForSong(songName:String):NseChart
	{
		var path:String = findSidecar(songName);
		if (path == null) return null;
		try
		{
			return fromFile(path);
		}
		catch (e:Dynamic)
		{
			trace('NSE: could not load ' + path + ' (' + e + '), falling back to the classic loader');
			return null;
		}
	}
	#else
	public static function loadForSong(songName:String):NseChart
	{
		return null;
	}
	#end

	/**
	 * Rebuilds an array of empty SwagSections carrying this chart's section metadata.
	 *
	 * Psych reads `SONG.notes[curSection]` for camera focus, alt animations and section
	 * length, and Conductor.mapBPMChanges() walks the same array. Keeping a section-only
	 * array around costs O(sections) instead of O(notes) and leaves every one of those code
	 * paths untouched, so streaming changes nothing above the note layer.
	 */
	public function buildSectionPlaceholders():Array<SwagSection>
	{
		var out:Array<SwagSection> = [];
		var total:Int = sectionCount > 0 ? sectionCount : sections.count;
		// beyond this a placeholder array is bigger than the rest of the game state; no real
		// song comes close (100k sections = 5.5 hours of 4/4 at 120 BPM)
		var limit:Int = 100000;
		if (total > limit) total = limit;
		var i:Int = 0;
		while (i < total)
		{
			var view:SwagSection = sections.section(i);
			out.push({
				sectionNotes: [],
				sectionBeats: view.sectionBeats,
				typeOfSection: 0,
				mustHitSection: view.mustHitSection,
				gfSection: view.gfSection,
				bpm: view.bpm,
				changeBPM: view.changeBPM,
				altAnim: view.altAnim
			});
			i++;
		}
		return out;
	}

	/** note type names referenced by the chart (drives custom note type Lua loading) */
	public function noteTypeSet():Array<String>
	{
		var out:Array<String> = [];
		var i:Int = 0;
		while (i < typeNames.length)
		{
			var t:String = typeNames[i];
			if (t != null && t.length > 0 && t != '') out.push(t);
			i++;
		}
		return out;
	}

	function readToc(r:NseReader):Void
	{
		var version:Int = r.u8() | (r.u8() << 8);
		if (version != Nse.VERSION) throw 'NSE: unsupported version ' + version;
		flags = r.u8() | (r.u8() << 8);
		lanes = r.u8();
		fidelity = r.u8();
		bpm = r.varintFloat() / 1000.0;
		speed = r.varintFloat() / 1000.0;
		noteCount = r.varintFloat();
		chunkCapacity = r.varint();
		sectionCount = r.varint();
		durationMs = r.varintFloat();

		// string table (note type names, event names/values)
		var nStrings:Int = r.varint();
		var i:Int = 0;
		typeNames = [];
		while (i < nStrings)
		{
			typeNames.push(r.string());
			i++;
		}

		// section timeline (run length encoded)
		var nRuns:Int = r.varint();
		sections = new NseSectionTimeline();
		i = 0;
		while (i < nRuns)
		{
			var runLen:Int = r.varint();
			var beats:Float = r.varintFloat() / 1000.0;
			var sFlags:Int = r.u8();
			var runBpm:Float = ((sFlags & Nse.SF_CHBPM) != 0) ? r.varintFloat() / 1000.0 : bpm;
			sections.push(runLen, beats, sFlags, runBpm);
			i++;
		}
		sections.finalize();
		if (sectionCount <= 0) sectionCount = sections.count;

		// BPM change map (already carries stepTime so Conductor never has to walk sections)
		var nBpm:Int = r.varint();
		bpmChanges = [];
		var t:Float = 0;
		i = 0;
		while (i < nBpm)
		{
			t += r.varintFloat();
			var changeBpm:Float = r.varintFloat() / 1000.0;
			var stepTime:Int = r.varint();
			bpmChanges.push({
				stepTime: stepTime,
				songTime: t,
				bpm: changeBpm,
				stepCrochet: Conductor.calculateCrochet(changeBpm) / 4
			});
			i++;
		}

		// chunk directory
		var nChunks:Int = r.varint();
		chunkCount = nChunks;
		chunkOff = [];
		chunkLen = [];
		chunkCnt = [];
		var off:Float = 0;
		i = 0;
		while (i < nChunks)
		{
			var c:Int = r.varint();
			var l:Int = r.varint();
			chunkCnt.push(c);
			chunkLen.push(l);
			chunkOff.push(off);
			off += l;
			i++;
		}

		// events
		var nEvents:Int = r.varint();
		events = [];
		t = 0;
		i = 0;
		while (i < nEvents)
		{
			t += r.varintFloat();
			var name:String = typeNames[r.varint()];
			var v1:String = typeNames[r.varint()];
			var v2:String = typeNames[r.varint()];
			events.push({strumTime: t + ClientPrefs.noteOffset, event: name, value1: v1, value2: v2});
			i++;
		}
	}

	public function totalNotes():Float
	{
		return noteCount;
	}

	public function chunkBytes():Float
	{
		var total:Float = 0;
		var i:Int = 0;
		while (i < chunkLen.length)
		{
			total += chunkLen[i];
			i++;
		}
		return total;
	}

	public function memoryFootprint():Float
	{
		// chunk directory (8 byte offset + 4 byte length + 4 byte count per chunk) + strings
		var footprint:Float = chunkLen.length * 16;
		var i:Int = 0;
		while (i < typeNames.length)
		{
			footprint += typeNames[i].length * 2;
			i++;
		}
		return footprint;
	}

	public function stats():String
	{
		var bytesPerNote:Float = noteCount > 0 ? chunkBytes() / noteCount : 0;
		return 'NSE ' + origin + ': ' + Std.string(noteCount) + ' notes, ' + chunkCount + ' chunks, '
			+ sections.runs() + ' section runs, ' + Std.string(Math.round(bytesPerNote * 100) / 100) + ' B/note, '
			+ Std.string(Math.round(memoryFootprint() / 1024)) + ' KiB resident';
	}

	public function close():Void
	{
		#if sys
		if (fileInput != null)
		{
			var input:sys.io.FileInput = cast fileInput;
			input.close();
			fileInput = null;
		}
		#end
	}
}
