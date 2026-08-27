# Game systems

Most games need input and frame timing immediately. Memory copies, DMA, and sound arrive when the first version works and a real constraint appears. Add one subsystem at a time so you can tell whether a new register change caused a problem.

The GBA is small enough that these systems meet in the same frame loop. Input changes game state; the game prepares display work; VBlank is the safe window for many video-memory updates; timers and interrupts help when polling no longer fits the job.
