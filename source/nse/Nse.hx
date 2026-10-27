package nse;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;

/**
 * NSE container primitives shared by the engine and the offline tools.
 *
 * The .nse format (version 1) is a compact, chunked, integer-only note container:
 *  - 2-3 bytes per note on average (lane + flags + delta time),
 *  - a dense chunk directory for O(log chunks) seeking,
 *  - run-length encoded section metadata so section lookup never needs O(sections) memory.
 *
 * See docs/NSE_FORMAT.md for the complete byte layout. Every multi byte integer is a
 * LEB128 varint, every other integer is little endian -- there is no float anywhere in
 * the file, so charts are portable across every Haxe target.
 */
class Nse
{
	// ---------------------------------------------------------------- container
	public static inline var MAGIC0:Int = 0x4E; // 'N'
	public static inline var MAGIC1:Int = 0x53; // 'S'
	public static inline var MAGIC2:Int = 0x45; // 'E'
	public static inline var MAGIC3:Int = 0x31; // '1'
	public static inline var VERSION:Int = 1;

	// header flags
	public static inline var F_EVENTS:Int = 1 << 0;
	public static inline var F_TYPES:Int = 1 << 1;
	public static inline var F_PROC:Int = 1 << 2;
	public static inline var F_SPANS:Int = 1 << 3;
	public static inline var F_CRC:Int = 1 << 4;

	// note flags (byte 2 of every note record)
	public static inline var NF_MUSTPRESS:Int = 1 << 0;
	public static inline var NF_SUSTAIN:Int = 1 << 1;
	public static inline var NF_GFNOTE:Int = 1 << 2;
	public static inline var NF_HASTYPE:Int = 1 << 3;
	public static inline var NF_LOWPRIORITY:Int = 1 << 4;
	public static inline var NF_HITCAUSESMISS:Int = 1 << 5;
	public static inline var NF_NOANIM:Int = 1 << 6;
	public static inline var NF_DTREPEAT:Int = 1 << 7;

	// section run flags
	public static inline var SF_MUSTHIT:Int = 1 << 0;
	public static inline var SF_GF:Int = 1 << 1;
	public static inline var SF_ALT:Int = 1 << 2;
	public static inline var SF_CHBPM:Int = 1 << 3;

	/** notes stored per chunk; a bigger value means a smaller directory but coarser seeks */
	public static inline var CHUNK_CAPACITY:Int = 4096;

	/** safety valve: refuse to allocate more than this for a single chunk buffer */
	public static inline var MAX_CHUNK_BYTES:Int = 1 << 20;

	public static function isNse(bytes:Bytes, ?pos:Int = 0):Bool
	{
		if (bytes == null || bytes.length < pos + 4) return false;
		return bytes.get(pos) == MAGIC0 && bytes.get(pos + 1) == MAGIC1
			&& bytes.get(pos + 2) == MAGIC2 && bytes.get(pos + 3) == MAGIC3;
	}
}

/**
 * Sequential byte reader over an in-memory chunk. Hot loops use the inline accessors,
 * so decoding a note costs two byte loads and at most three varints.
 */
class NseReader
{
	public var bytes:Bytes;
	public var pos:Int = 0;
	public var limit:Int = 0;
	/** when true, reads past `limit` are recorded in `truncated` instead of throwing */
	public var bounded:Bool = false;
	public var truncated:Bool = false;

	public function new(bytes:Bytes, ?pos:Int = 0, ?limit:Int = -1)
	{
		this.bytes = bytes;
		this.pos = pos;
		this.limit = limit < 0 ? (bytes != null ? bytes.length : 0) : limit;
	}

	public inline function atEnd():Bool
	{
		return pos >= limit;
	}

	public inline function remaining():Int
	{
		return limit - pos;
	}

	public inline function u8():Int
	{
		if (bounded && pos >= limit)
		{
			truncated = true;
			return 0;
		}
		return bytes.get(pos++);
	}

	public function varint():Int
	{
		var b:Int = u8();
		if (b < 0x80) return b;
		var result:Int = b & 0x7F;
		var shift:Int = 7;
		while (true)
		{
			b = u8();
			result |= (b & 0x7F) << shift;
			if (b < 0x80) break;
			shift += 7;
			if (shift > 28) break; // longer varints use varintFloat
		}
		return result;
	}

	/** varint for values that may exceed 2^31 (note counts, song durations, ...) */
	public function varintFloat():Float
	{
		var b:Int = u8();
		var result:Float = (b & 0x7F);
		var mul:Float = 128;
		while (b >= 0x80)
		{
			b = u8();
			result += (b & 0x7F) * mul;
			mul *= 128;
		}
		return result;
	}

	public function string():String
	{
		var len:Int = varint();
		if (bounded && pos + len > limit)
		{
			truncated = true;
			len = limit - pos;
			if (len < 0) len = 0;
		}
		var s:String = bytes.getString(pos, len);
		pos += len;
		return s;
	}

	public function skip(n:Int):Void
	{
		pos += n;
	}
}

/** Growable little helper used by the offline chart compiler and by ProcChart. */
class NseWriter
{
	var buffer:BytesBuffer = new BytesBuffer();

	public function new() {}

	public inline function u8(v:Int):Void
	{
		buffer.addByte(v & 0xFF);
	}

	public function varint(v:Int):Void
	{
		var value:Int = v;
		if (value < 0) value = 0;
		while (true)
		{
			var b:Int = value & 0x7F;
			value = value >>> 7;
			if (value != 0)
			{
				buffer.addByte(b | 0x80);
			}
			else
			{
				buffer.addByte(b);
				return;
			}
		}
	}

	public function varintFloat(v:Float):Void
	{
		var value:Float = v;
		if (value < 0) value = 0;
		while (true)
		{
			var b:Int = Std.int(value % 128);
			value = Math.ffloor(value / 128);
			if (value > 0)
			{
				buffer.addByte(b | 0x80);
			}
			else
			{
				buffer.addByte(b);
				return;
			}
		}
	}

	public function string(s:String):Void
	{
		var bytes:Bytes = Bytes.ofString(s);
		varint(bytes.length);
		buffer.add(bytes);
	}

	public inline function raw(bytes:Bytes):Void
	{
		buffer.add(bytes);
	}

	public function length():Int
	{
		return buffer.length;
	}

	public function getBytes():Bytes
	{
		return buffer.getBytes();
	}
}

/** Plain mutable note record handed to the live window (one instance is reused). */
class NseNoteData
{
	public var t:Float = 0;      // strum time in ms
	public var span:Float = 0;   // sustain length in ms (0 = tap note)
	public var lane:Int = 0;
	public var flags:Int = 0;
	public var typeIdx:Int = -1;
	public var typeName:String = null;

	public function new() {}

	public inline function mustPress():Bool
	{
		return (flags & Nse.NF_MUSTPRESS) != 0;
	}

	public inline function isSustain():Bool
	{
		return (flags & Nse.NF_SUSTAIN) != 0;
	}

	public inline function gfNote():Bool
	{
		return (flags & Nse.NF_GFNOTE) != 0;
	}

	public inline function lowPriority():Bool
	{
		return (flags & Nse.NF_LOWPRIORITY) != 0;
	}

	public inline function hitCausesMiss():Bool
	{
		return (flags & Nse.NF_HITCAUSESMISS) != 0;
	}

	public inline function noAnimation():Bool
	{
		return (flags & Nse.NF_NOANIM) != 0;
	}
}
