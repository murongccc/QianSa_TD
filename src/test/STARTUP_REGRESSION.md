# Startup repair, 2026-09-07

`bmp_read.scan_done` is a persistent level, cleared on reset or a new scan.
It is not a one-cycle pulse. A matching header updates the catalogue on the
following clock; the persistent completion level lets the session start later.
An additional latch triggered by `scan_found_valid` was unnecessary and could
prematurely mark a multi-image scan as completed.

The previous bound of LBA 2048 excluded all file headers beyond that address.
FAT32 volumes commonly start at LBA 2048, with file data later. The current
top restores the earlier 0..131071 search coverage and still requests just
one image. It does not restore multi-image discovery or accelerate the search
for the first image: those require further catalogue work. The unconditional
first-match stop inside the reusable BMP reader was removed, so its caller's
target count works again.

The SD arbiter now captures a request and its address, locks the return path
until sector completion, inserts an idle gap, and round-robins when both clients
request. It does not infer transport idle from a client's request deassertion.

Status meanings in this revision:

- 1: BMP idle (not proof of successful discovery).
- 2: BMP scanning or reading a header.
- 3: waiting for SDRAM write request acknowledgement.
- 4: BMP pixel loading.
- 5: WAV lookup active.
- 6: WAV format accepted (not proof HDMI sound reached the monitor).
- 7: WAV entry found but format not yet accepted; includes header loading.
- 8: BMP scan finished without a matching image.
- 9: WAV locator finished without finding an entry.

The existing WAV locator only searches the first root-directory sector and
accepts a canonical 44-byte PCM WAV header. These remaining restrictions can
independently cause silence. This startup repair does not claim full WAV/FAT32
compatibility or audio hardware validation.

## Tests

Run from the repository root with ModelSim on PATH:

```bat
vlib sim/startup_regression_work
vlog -work sim/startup_regression_work src/sd_sector_arbiter.v src/fat32_wav_reader.v src/SD/bmp_read.v src/media_session_controller.v src/sd_media_pipeline.v src/test/tb_sd_sector_arbiter.v src/test/tb_media_startup_regression.v
vsim -c -onfinish exit -lib sim/startup_regression_work -do src/test/run_startup_regression.do tb_sd_sector_arbiter
vsim -c -onfinish exit -lib sim/startup_regression_work -do src/test/run_startup_regression.do tb_media_startup_regression
```

The startup test runs two real media pipelines with different scan bounds and
a sector model containing a BMP at LBA 2050. It asserts that the short search
fails explicitly, the expanded search loads a pixel payload and commits the
frame, scan_done stays high, and the WAV lookup ends without removing video.
The deliberately short synthetic BMP exercises control handshakes, not full
640x480 pixel transport or SDRAM timing.

The arbiter test checks complete 512-byte responses, held requests, address
stability even after request withdrawal, alternating ownership and done routing.

IMPORTANT: The startup sector transport is named `media_startup_sector_model`
and is guarded by `MEDIA_STARTUP_MODEL`. The board build always instantiates
the real `src/SD/sd_card_top.v`; it cannot be replaced by this test model.
Project test entries have `AutoExcluded`, `UsedInSyn=false`, and
`UsedInP&R=false`.

Validation this session: ModelSim vlog compilation passed, zero errors and
warnings. vsim and vsimk could not start because of `couldn't open socket:
invalid argument`, including an outside-sandbox retry. Runtime assertions have
NOT been reported as passed. TD synthesis/PNR and board testing remain pending.
