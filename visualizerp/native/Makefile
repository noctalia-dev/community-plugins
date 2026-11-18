BIN     := ../bin/pwscope
CFLAGS  ?= -O2 -g
CFLAGS  += -Wall -Wextra -Wno-unused-parameter -std=gnu11
CFLAGS  += $(shell pkg-config --cflags libpipewire-0.3)
LDLIBS  += $(shell pkg-config --libs libpipewire-0.3) -lm

all: $(BIN)

$(BIN): pwscope.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f $(BIN)

.PHONY: all clean
