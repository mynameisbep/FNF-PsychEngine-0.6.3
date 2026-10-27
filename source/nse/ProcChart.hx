package nse;

import haxe.io.Bytes;

/**
 * Procedural ("infinite") charts.
 *
 * A procedural chart stores a 9-varint descriptor instead of a note payload, and derives
 * every note from a 32-bit splitmix hash of (seed, step, index). That means:
 *   - O(1) storage for *any* note count -- a billion note chart is ~40 bytes on disk,
 *   - O(1) random access (the step index is `time / stepMs`),
 *   - perfectly deterministic across runs, platforms and tools (same hash everywhere).
 *
 * Used by the stress-test generator, by `refbench`, and as a fallback for charts that would
 * otherwise exceed disk/memory budgets (see NseEngine.PROC_THRESHOLD).
 */
class ProcSpec
{
	public var seed:Int = 0x2F6E2B1;
	public var steps:Float = 0;          // total steps in the song
	public var notesPerStep:Int = 1;     // simultaneous notes per step (a "chord" width)
	public var lanes:Int = 4;
	public var sustainEvery:Int = 0;     // add a sustain on the first note of every N steps
	public var chordEvery:Int = 0;       // stack notes on distinct lanes every N steps
	public var stepMs:Float = 100;       // step length in ms
	public var bpm:Float = 150;
	public var speed:Float = 1;

	public function new() {}

	public function noteCount():Float
	{
		return steps * notesPerStep;
	}

	public function durationMs():Float
	{
		return steps * stepMs;
	}

	public static function create(seed:Int, notes:Float, notesPerStep:Int, lanes:Int, ?bpm:Float = 150):ProcSpec
	{
		var spec:ProcSpec = new ProcSpec();
		spec.seed = seed;
		spec.notesPerStep = notesPerStep < 1 ? 1 : notesPerStep;
		spec.lanes = lanes < 1 ? 1 : lanes;
		spec.bpm = bpm;
		spec.stepMs = (60000.0 / bpm) / 4.0;
		spec.steps = Math.ffloor(notes / spec.notesPerStep);
		spec.sustainEvery = 8;
		spec.chordEvery = 4;
		return spec;
	}

	public function toBytes():Bytes
	{
		var w:NseWriter = new NseWriter();
		w.varint(seed);
		w.varintFloat(steps);
		w.varint(notesPerStep);
		w.varint(lanes);
		w.varint(sustainEvery);
		w.varint(chordEvery);
		w.varintFloat(Math.round(stepMs * 1000));
		w.varintFloat(Math.round(bpm * 1000));
		w.varintFloat(Math.round(speed * 1000));
		return w.getBytes();
	}

	public static function parse(bytes:Bytes, pos:Int):ProcSpec
	{
		var spec:ProcSpec = new ProcSpec();
		var r:NseReader = new NseReader(bytes, pos);
		r.bounded = true;
		spec.seed = r.varint();
		spec.steps = r.varintFloat();
		spec.notesPerStep = r.varint();
		spec.lanes = r.varint();
		spec.sustainEvery = r.varint();
		spec.chordEvery = r.varint();
		spec.stepMs = r.varintFloat() / 1000.0;
		spec.bpm = r.varintFloat() / 1000.0;
		spec.speed = r.varintFloat() / 1000.0;
		return spec;
	}

	public function describe():String
	{
		return 'procedural: seed=' + seed + ' steps=' + Std.string(steps) + ' x' + notesPerStep
			+ ' notes/step, ' + Std.string(Math.round(stepMs * 100) / 100) + ' ms/step, '
			+ Std.string(durationMs() / 1000) + 's';
	}
}

/**
 * Infinite, deterministic, time ordered note stream. Zero storage, O(1) seek.
 * Must stay byte-for-byte compatible with tools/nse/nse_ref.py and tools/refbench/refbench.c.
 */
class ProcNoteStream implements NoteSource
{
	public static inline var HASH_A:Int = 0x9E3779B9;
	public static inline var HASH_B:Int = 0x85EBCA6B;
	public static inline var HASH_C:Int = 0x21F0AAAD;
	public static inline var HASH_D:Int = 0x735A2D97;

	var spec:ProcSpec;
	var step:Float = 0;
	var k:Int = 0;
	var cachedStep:Float = -1;
	var curLanes:Array<Int> = [];
	var streamed:Float = 0;
	var data:NseNoteData = new NseNoteData();

	public function new(spec:ProcSpec)
	{
		this.spec = spec;
		reset();
	}

	/** 32-bit splitmix hash; identical to mix32() in the Python and C reference tools */
	public static inline function mix32(x:Int):Int
	{
		var z:Int = (x + HASH_A) | 0;
		z = mul32(z ^ (z >>> 16), HASH_C);
		z = mul32(z ^ (z >>> 15), HASH_D);
		return z ^ (z >>> 15);
	}

	/** lower 32 bits of a product, on every target */
	public static inline function mul32(a:Int, b:Int):Int
	{
		return (a * b) | 0;
	}

	function buildLanes():Void
	{
		cachedStep = step;
		curLanes = [];
		var sIdx:Int = Std.int(step);
		var base:Int = mix32(spec.seed ^ mul32(sIdx, HASH_A));
		var chord:Bool = spec.chordEvery > 0 && (sIdx % spec.chordEvery) == 0;
		var i:Int = 0;
		while (i < spec.notesPerStep)
		{
			var v:Int = mix32(base + mul32(i, HASH_B));
			var lane:Int;
			if (chord)
			{
				lane = (i + (v >>> 8)) % spec.lanes;
			}
			else
			{
				lane = (v >>> 1) % spec.lanes;
			}
			curLanes.push(lane);
			i++;
		}
		// insertion sort keeps the chord ordered without allocating another array
		i = 1;
		while (i < curLanes.length)
		{
			var v2:Int = curLanes[i];
			var j:Int = i - 1;
			while (j >= 0 && curLanes[j] > v2)
			{
				curLanes[j + 1] = curLanes[j];
				j--;
			}
			curLanes[j + 1] = v2;
			i++;
		}
	}

	public function next():Bool
	{
		while (step < spec.steps)
		{
			if (cachedStep != step) buildLanes();
			if (k >= spec.notesPerStep)
			{
				step += 1;
				k = 0;
				continue;
			}
			data.t = step * spec.stepMs;
			data.lane = curLanes[k];
			data.flags = Nse.NF_MUSTPRESS;
			data.span = 0;
			data.typeIdx = -1;
			data.typeName = null;
			if (spec.sustainEvery > 0 && k == 0 && (Std.int(step) % spec.sustainEvery) == 0)
			{
				data.span = spec.stepMs * 3;
				data.flags |= Nse.NF_SUSTAIN;
			}
			// alternate sections every 16 steps so camera/mustHitSection logic still works
			if (Math.ffloor(step / 16) % 2 == 1)
			{
				data.flags &= ~Nse.NF_MUSTPRESS;
			}
			k++;
			streamed++;
			return true;
		}
		return false;
	}

	public function current():NseNoteData
	{
		return data;
	}

	public function peekTime():Float
	{
		if (step >= spec.steps) return Math.POSITIVE_INFINITY;
		return step * spec.stepMs;
	}

	public function seek(t:Float):Void
	{
		if (spec.stepMs <= 0)
		{
			step = 0;
		}
		else
		{
			step = Math.ffloor(t / spec.stepMs);
			if (step < 0) step = 0;
			if (step > spec.steps) step = spec.steps;
		}
		k = 0;
		cachedStep = -1;
		streamed = 0;
	}

	public function reset():Void
	{
		step = 0;
		k = 0;
		cachedStep = -1;
		curLanes = [];
		streamed = 0;
	}

	public function totalNotes():Float
	{
		return spec.noteCount();
	}

	public inline function streamedNotes():Float
	{
		return streamed;
	}

	public inline function specRef():ProcSpec
	{
		return spec;
	}
}
