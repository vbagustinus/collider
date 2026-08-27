# Makefile for metal-kangaroo (Apple Silicon, no Xcode needed)
CC ?= clang
CFLAGS = -fobjc-arc -framework Foundation -framework Metal -O2 -Wall
BIN = metal-kangaroo

all: $(BIN)

$(BIN): main.m kangaroo.metal
	$(CC) $(CFLAGS) main.m -o $(BIN)

clean:
	rm -f $(BIN)

.PHONY: all clean
