# Save demo

This ROM uses an SRAM-backed `gba.save.SlotManager` with three logical slots. It creates slot zero on its first run, loads it after an emulator restart, increments the stored counter with **A**, and erases the slot with **B**.

The center rectangle is blue after creating or erasing the slot, green after a successful load or store, and red when a save operation fails or an existing record needs recovery. mGBA's log window shows the same events.
