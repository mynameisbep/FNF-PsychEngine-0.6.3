package nse;

import Note;

/**
 * Sprite pool for streamed notes.
 *
 * In the classic (materialised) loader every note of the chart is constructed once, up
 * front. When a chart is streamed we instead construct notes on demand -- so construction
 * cost would land on the frame that spawns them, which is exactly the frame we cannot
 * afford to stall.
 *
 * The pool fixes that by keying notes on everything that affects their visuals
 * (lane, head/body/tail, note type) and recycling instances. After warm-up a note costs
 * ~40 field writes instead of loading atlas frames and rebuilding animations.
 */
class NotePool
{
	public var created(default, null):Int = 0;
	public var reused(default, null):Int = 0;
	public var released(default, null):Int = 0;

	var free:Map<String, Array<Note>> = new Map<String, Array<Note>>();

	public function new() {}

	static inline function keyOf(lane:Int, kind:Int, type:String):String
	{
		return lane + '|' + kind + '|' + (type == null ? '' : type);
	}

	/**
	 * @param kind 0 = head/tap note, 1 = sustain body (stretched), 2 = sustain tail
	 */
	public function acquire(lane:Int, kind:Int, type:String, strumTime:Float, mustPress:Bool,
		span:Float, prev:Note):Note
	{
		var key:String = keyOf(lane, kind, type);
		var bucket:Array<Note> = free.get(key);
		var note:Note = null;
		if (bucket != null && bucket.length > 0)
		{
			note = bucket.pop();
			note.nsePooled = false;
			reused++;
		}
		else
		{
			note = new Note(strumTime, lane, prev, kind != 0);
			if (type != null && type.length > 0) note.noteType = type;
			created++;
			note.poolKey = key;
			note.poolX = note.x;
			note.poolY = note.y;
			note.poolOffsetX = note.offsetX;
			note.poolScaleY = note.scale.y;
		}
		note.recycleTo(strumTime, lane, mustPress, span, kind, prev);
		return note;
	}

	public function release(note:Note):Void
	{
		if (note == null || note.poolKey == null || note.nsePooled) return;
		note.nsePooled = true;
		note.kill();
		note.exists = false;
		note.visible = false;
		note.active = false;
		var bucket:Array<Note> = free.get(note.poolKey);
		if (bucket == null)
		{
			bucket = [];
			free.set(note.poolKey, bucket);
		}
		if (bucket.length < 4096) bucket.push(note);
		else note.nsePooled = false;
		released++;
	}

	public function clear():Void
	{
		for (key in free.keys())
		{
			var bucket:Array<Note> = free.get(key);
			if (bucket != null)
			{
				var i:Int = 0;
				while (i < bucket.length)
				{
					bucket[i].destroy();
					i++;
				}
			}
		}
		free = new Map<String, Array<Note>>();
	}

	public function stats():String
	{
		return 'pool: ' + created + ' created, ' + reused + ' reused, ' + released + ' released';
	}
}
