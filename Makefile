CC = gcc
CFLAGS = -Wall -Wextra -pthread
LDFLAGS = -lrt -lpthread
BINDIR = bin
SRCDIR = src

.PHONY: all clean

all: $(BINDIR)/evaluator

$(BINDIR)/evaluator: $(SRCDIR)/main.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(BINDIR)/evaluator
