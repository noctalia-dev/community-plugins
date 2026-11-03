# Builds the playback monitor into the plugin's bin/ directory, next to this
# native/ folder. service.luau runs `make -C native` on first use.
BIN     := ../bin/noctalia-audio-monitor
CFLAGS  ?= -O2 -g
CFLAGS  += -Wall -Wextra -std=gnu11
CFLAGS  += $(shell pkg-config --cflags libpipewire-0.3)
LDLIBS  += $(shell pkg-config --libs libpipewire-0.3) -lm

all: $(BIN)

$(BIN): audio-monitor.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f $(BIN)

.PHONY: all clean
