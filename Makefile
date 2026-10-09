.PHONY: all audio-monitor install clean

PREFIX ?= $(HOME)/.local/share/noctalia/plugins
PLUGIN_DIR = $(PREFIX)/audio-sticker

all: audio-monitor

audio-monitor:
	$(MAKE) -C audio-monitor
	mkdir -p bin
	cp audio-monitor/noctalia-audio-monitor bin/

install: audio-monitor
	mkdir -p $(PLUGIN_DIR)
	rsync -av --exclude='.git' --exclude='audio-monitor/noctalia-audio-monitor' \
		plugin.toml widget.luau translations bin audio-monitor README.md LICENSE \
		$(PLUGIN_DIR)/

clean:
	$(MAKE) -C audio-monitor clean
	rm -f bin/noctalia-audio-monitor
