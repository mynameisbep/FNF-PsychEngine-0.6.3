package nse;

/**
 * A pull based, forward-only (seekable) stream of notes.
 *
 * Implementations must return notes in non-decreasing strumTime order and must never
 * allocate per note: `next()` decodes into `current()`, a single reusable record.
 *
 * The three implementations are:
 *   - NseMemoryStream : payload already in RAM (chart compiled in memory / embedded assets)
 *   - NseFileStream   : payload streamed from disk with a fixed window (desktop/Android)
 *   - ProcNoteStream  : generated on the fly from a seed (unbounded note counts)
 */
interface NoteSource
{
	/** true when `next()` decoded a note; false once the chart is exhausted */
	public function next():Bool;

	/** the record filled by the last successful next() */
	public function current():NseNoteData;

	/** strum time of the next note, Math.POSITIVE_INFINITY when exhausted */
	public function peekTime():Float;

	/** reposition: the next note will be the first one with strumTime >= t */
	public function seek(t:Float):Void;

	public function reset():Void;

	/** total notes in the chart (exact for file charts, derived for procedural ones) */
	public function totalNotes():Float;

	/** number of notes handed out since the last reset, used for stats/HUD */
	public function streamedNotes():Float;
}
