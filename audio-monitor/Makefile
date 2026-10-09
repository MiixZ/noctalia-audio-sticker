# noctalia-audio-monitor Makefile

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
LDFLAGS ?=

PKG_CONFIG ?= pkg-config

PIPEWIRE_CFLAGS := $(shell $(PKG_CONFIG) --cflags libpipewire-0.3)
PIPEWIRE_LIBS   := $(shell $(PKG_CONFIG) --libs libpipewire-0.3) -lm

TARGET = noctalia-audio-monitor

.PHONY: all clean

all: $(TARGET)

$(TARGET): audio-monitor.c
	$(CC) $(CFLAGS) $(PIPEWIRE_CFLAGS) -o $@ $< $(LDFLAGS) $(PIPEWIRE_LIBS)

clean:
	rm -f $(TARGET)
