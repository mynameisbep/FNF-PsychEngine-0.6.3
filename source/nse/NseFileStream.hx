package nse;

#if sys
import haxe.io.Bytes;
import sys.io.File;
import sys.io.FileInput;
import sys.io.FileSeek;

/**
 * Note stream that reads a .nse payload straight off the disk.
 *
 * The whole point: memory usage is O(chunk directory) + one chunk window, no matter how
 * big the chart is. A 10^9 note chart (2.0 GiB on disk) runs in ~5 MiB of RAM.
 *
 * Reading is sequential during normal play (one `readFullBytes` per 4096 notes) and uses
 * `seek` only for practice mode / mid-song starting.
 */
class NseFileStream implements NoteSource
{
	var input:FileInput;
	var payloadOffset:Int;
	var chunkOff:Array<Float>;
	var chunkLen:Array<Int>;
	var chunkCnt:Array<Int>;
	var chunkCapacity:Int;
	var typeNames:Array<String>;

	var buf:Bytes;
	var bufLen:Int = 0;
	/** tiny buffer used to peek at a chunk's leading base time during a seek */
	var baseBuf:Bytes = Bytes.alloc(16);

	var chunk:Int = -1;
	var idx:Int = 0;
	var cnt:Int = 0;
	var pos:Int = 0;
	var limit:Int = 0;
	var curT:Float = 0;
	var prevDt:Int = 0;
	var streamed:Float = 0;

	var data:NseNoteData = new NseNoteData();
	var pendingData:NseNoteData = new NseNoteData();
	var pending:Bool = false;

	public function new(input:FileInput, payloadOffset:Int, chunkOff:Array<Float>, chunkLen:Array<Int>,
		chunkCnt:Array<Int>, chunkCapacity:Int, typeNames:Array<String>)
	{
		this.input = input;
		this.payloadOffset = payloadOffset;
		this.chunkOff = chunkOff;
		this.chunkLen = chunkLen;
		this.chunkCnt = chunkCnt;
		this.chunkCapacity = chunkCapacity;
		this.typeNames = typeNames;

		var maxLen:Int = 0;
		var i:Int = 0;
		while (i < chunkLen.length)
		{
			if (chunkLen[i] > maxLen) maxLen = chunkLen[i];
			i++;
		}
		buf = Bytes.alloc(maxLen + 64);
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
		bufLen = chunkLen[i];
		input.seek(payloadOffset + Std.int(chunkOff[i]), FileSeek.SeekBegin);
		input.readFullBytes(buf, 0, bufLen);

		pos = 0;
		limit = bufLen;
		cnt = chunkCnt[i];
		idx = 0;
		prevDt = 0;
		var r:NseReader = new NseReader(buf, 0, limit);
		curT = r.varintFloat();
		pos = r.pos;
		return true;
	}

	function decodeInto(target:NseNoteData):Bool
	{
		while (idx >= cnt)
		{
			if (!loadChunk(chunk + 1)) return false;
		}
		if (pos + 2 > limit) return false;

		var lane:Int = buf.get(pos++);
		var flags:Int = buf.get(pos++);
		var dt:Int;
		if ((flags & Nse.NF_DTREPEAT) != 0)
		{
			dt = prevDt;
		}
		else
		{
			var r:NseReader = new NseReader(buf, pos, limit);
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
			var r2:NseReader = new NseReader(buf, pos, limit);
			target.span = r2.varintFloat();
			pos = r2.pos;
		}
		if ((flags & Nse.NF_HASTYPE) != 0)
		{
			var r3:NseReader = new NseReader(buf, pos, limit);
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

	/**
	 * Reads only the leading `baseMs` varint of a chunk. Uses its own buffer so the decode
	 * window (`buf`) is never invalidated in the middle of the binary search.
	 */
	function chunkBaseTime(i:Int):Float
	{
		var len:Int = chunkLen[i];
		if (len > 16) len = 16;
		if (len < 1) return 0;
		input.seek(payloadOffset + Std.int(chunkOff[i]), FileSeek.SeekBegin);
		input.readFullBytes(baseBuf, 0, len);
		var r:NseReader = new NseReader(baseBuf, 0, len);
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

	public function close():Void
	{
		if (input != null)
		{
			input.close();
			input = null;
		}
	}
}
#else
/** Non-sys targets cannot stream from disk; charts must be embedded and use NseMemoryStream. */
class NseFileStream
{
	public function new() {}
}
#end
