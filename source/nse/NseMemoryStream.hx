package nse;

import haxe.io.Bytes;

/**
 * Note stream over a payload that already lives in RAM (charts compiled in memory,
 * embedded assets, tools).
 *
 * Decoding is two array reads plus at most three varints per note: no allocation, no
 * per-note objects. `peekTime()` is O(1) because the decoded record is cached.
 */
class NseMemoryStream implements NoteSource
{
	var payload:Bytes;
	var chunkOff:Array<Float>;   // byte offset of every chunk inside `payload`
	var chunkLen:Array<Int>;
	var chunkCnt:Array<Int>;
	var chunkCapacity:Int;
	var typeNames:Array<String>;

	var chunk:Int = -1;
	var idx:Int = 0;
	var cnt:Int = 0;
	var limit:Int = 0;
	var pos:Int = 0;
	var curT:Float = 0;
	var prevDt:Int = 0;

	var streamed:Float = 0;

	var data:NseNoteData = new NseNoteData();
	var pendingData:NseNoteData = new NseNoteData();
	var pending:Bool = false;

	public function new(payload:Bytes, chunkOff:Array<Float>, chunkLen:Array<Int>, chunkCnt:Array<Int>,
		chunkCapacity:Int, typeNames:Array<String>)
	{
		this.payload = payload;
		this.chunkOff = chunkOff;
		this.chunkLen = chunkLen;
		this.chunkCnt = chunkCnt;
		this.chunkCapacity = chunkCapacity;
		this.typeNames = typeNames;
		reset();
	}

	function loadChunk(i:Int):Bool
	{
		if (i < 0 || i >= chunkLen.length)
		{
			chunk = chunkLen.length;
			cnt = 0;
			idx = 0;
			return false;
		}
		chunk = i;
		pos = Std.int(chunkOff[i]);
		limit = pos + chunkLen[i];
		cnt = chunkCnt[i];
		idx = 0;
		prevDt = 0;
		var r:NseReader = new NseReader(payload, pos, limit);
		curT = r.varintFloat();
		pos = r.pos;
		return true;
	}

	/** decodes the next note into `target`; returns false at the end of the chart */
	function decodeInto(target:NseNoteData):Bool
	{
		while (idx >= cnt)
		{
			if (!loadChunk(chunk + 1)) return false;
		}
		if (pos + 2 > limit) return false;

		var lane:Int = payload.get(pos++);
		var flags:Int = payload.get(pos++);
		var dt:Int;
		if ((flags & Nse.NF_DTREPEAT) != 0)
		{
			dt = prevDt;
		}
		else
		{
			var r:NseReader = new NseReader(payload, pos, limit);
			dt = r.varint();
			prevDt = dt;
			pos = r.pos;
		}
		curT += dt;

		target.t = curT;
		target.lane = lane;
		target.flags = flags;
		target.span = 0;
		target.typeIdx = -1;
		target.typeName = null;

		if ((flags & Nse.NF_SUSTAIN) != 0)
		{
			var r2:NseReader = new NseReader(payload, pos, limit);
			target.span = r2.varintFloat();
			pos = r2.pos;
		}
		if ((flags & Nse.NF_HASTYPE) != 0)
		{
			var r3:NseReader = new NseReader(payload, pos, limit);
			var ti:Int = r3.varint();
			pos = r3.pos;
			target.typeIdx = ti;
			target.typeName = (typeNames != null && ti >= 0 && ti < typeNames.length) ? typeNames[ti] : null;
		}

		idx++;
		return true;
	}

	static inline function copyNote(from:NseNoteData, to:NseNoteData):Void
	{
		to.t = from.t;
		to.lane = from.lane;
		to.flags = from.flags;
		to.span = from.span;
		to.typeIdx = from.typeIdx;
		to.typeName = from.typeName;
	}

	public function next():Bool
	{
		if (pending)
		{
			copyNote(pendingData, data);
			pending = false;
			streamed++;
			return true;
		}
		if (!decodeInto(data)) return false;
		streamed++;
		return true;
	}

	public function current():NseNoteData
	{
		return data;
	}

	public function peekTime():Float
	{
		if (pending) return pendingData.t;
		if (!decodeInto(pendingData)) return Math.POSITIVE_INFINITY;
		pending = true;
		return pendingData.t;
	}

	public function seek(t:Float):Void
	{
		pending = false;
		var target:Int = 0;
		var hi:Int = chunkLen.length - 1;
		if (hi >= 0)
		{
			var lo:Int = 0;
			while (lo < hi)
			{
				var mid:Int = (lo + hi + 1) >> 1;
				if (chunkBaseTime(mid) <= t) lo = mid;
				else hi = mid - 1;
			}
			target = lo;
		}
		loadChunk(target);
		while (true)
		{
			if (!decodeInto(pendingData))
			{
				pending = false;
				return;
			}
			if (pendingData.t >= t)
			{
				pending = true;
				return;
			}
		}
	}

	function chunkBaseTime(i:Int):Float
	{
		var r:NseReader = new NseReader(payload, Std.int(chunkOff[i]), Std.int(chunkOff[i] + chunkLen[i]));
		return r.varintFloat();
	}

	public function reset():Void
	{
		pending = false;
		chunk = -1;
		idx = 0;
		cnt = 0;
		pos = 0;
		limit = 0;
		curT = 0;
		prevDt = 0;
		streamed = 0;
		loadChunk(0);
	}

	public function totalNotes():Float
	{
		var n:Float = 0;
		var i:Int = 0;
		while (i < chunkCnt.length)
		{
			n += chunkCnt[i];
			i++;
		}
		return n;
	}

	public inline function streamedNotes():Float
	{
		return streamed;
	}

	public inline function chunkCount():Int
	{
		return chunkLen.length;
	}

	public inline function capacity():Int
	{
		return chunkCapacity;
	}
}
