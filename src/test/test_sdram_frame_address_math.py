"""Check the fixed 640x480, 256-word frame-buffer address configuration."""

FRAME_WIDTH = 640
FRAME_HEIGHT = 480
FRAME_WORDS = FRAME_WIDTH * FRAME_HEIGHT
BURST_WORDS = 256
ADDRESS_MASK = (1 << 21) - 1


def check_frame(slot: int, flip: bool) -> None:
    base = slot * FRAME_WORDS
    address = base + ((FRAME_HEIGHT - 1) * FRAME_WIDTH if flip else 0)
    x = 0
    for word in range(FRAME_WORDS):
        row, column = divmod(word, FRAME_WIDTH)
        expected_row = FRAME_HEIGHT - 1 - row if flip else row
        expected = base + expected_row * FRAME_WIDTH + column
        assert address == expected, (slot, flip, word, address, expected)
        assert address <= ADDRESS_MASK
        if flip and x == FRAME_WIDTH - 1:
            address -= 2 * FRAME_WIDTH - 1
            x = 0
        else:
            address += 1
            if flip:
                x += 1


def main() -> None:
    assert FRAME_WORDS % BURST_WORDS == 0
    burst_count = FRAME_WORDS // BURST_WORDS
    assert burst_count == 1200
    assert burst_count < (1 << 11)
    for completed in range(burst_count + 1):
        assert completed * BURST_WORDS == (completed << 8)
    for length in (1, 255, 256, 257, FRAME_WORDS - 1, FRAME_WORDS):
        completed = 0
        while completed * BURST_WORDS < length:
            completed += 1
        assert completed == (length + BURST_WORDS - 1) // BURST_WORDS
    for slot in range(5):
        for flip in (False, True):
            check_frame(slot, flip)
    print("PASS: five frame slots, both row orders, full 640x480 address range")


if __name__ == "__main__":
    main()
