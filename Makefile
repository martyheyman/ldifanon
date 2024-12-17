OS = $(shell cc --version | awk 'NR == 1 {print $$1;}')

ifeq "Apple" "$(OS)"
CPPFLAGS = -Iinclude
YYGEN = sed 's/%empty//g'
PARSE.Y = libldif/parse.yy
else
#PPFLAGS = -D_GNU_SOURCE -D_BSD_SOURCE -D_XOPEN_SOURCE=500
CPPFLAGS = -D_GNU_SOURCE -D_DEFAULT_SOURCE -D_XOPEN_SOURCE=500
YYGEN = cat
PARSER.OUT = --report-file=parser.out
PARSE.Y = libldif/parse.y
endif

CFLAGS = -g -std=c11 -O0 -fPIC
PREFIX = /usr/local

# To use uninstalled libldif.so, set DEVFLAGS
ifeq "$(USER)" "jklowden"
DEVFLAGS =             -L$(PWD)/libldif \
	  -Wl,-rpath -Wl,$(PWD)/libldif
endif

LDFLAGS = $(DEVFLAGS) -L $(PREFIX)/lib \
	  -Wl,-rpath -Wl,$(PREFIX)/lib

LDLIBS = -lldif -lsqlite3

CXXFLAGS = -g -O0 -std=c++11

YACC = bison
YFLAGS = --debug --token-table --defines=libldif/parse.h $(PARSER.OUT) --verbose

LEX = flex

TGT.BIN = bin/ldifanon bin/ldifq
TGT.MAN = share/man/man1/ldifanon.1
TGT.LIB = lib/libldif.so
LIB.MAN = share/man/man3/libldif.3
LIB.H   = include/libldif.h

all: ldifanon libldif/libldif.so cscope.files

install: $(addprefix $(PREFIX)/, \
	$(TGT.BIN) $(TGT.MAN) $(TGT.LIB) $(LIB.MAN) $(LIB.H))

install-lib: $(addprefix $(PREFIX)/, $(TGT.LIB) $(LIB.MAN) $(LIB.H))

$(PREFIX)/$(TGT.BIN): ldifanon ldifq
	mkdir -p   $(dir $@)
	install $^ $(dir $@)

$(PREFIX)/$(TGT.MAN): $(notdir $(TGT.MAN))
	install -D -m0600 $^ $@

$(PREFIX)/$(TGT.LIB): libldif/libldif.so
	install -D $^ $@

$(PREFIX)/$(LIB.MAN): libldif/$(notdir $(LIB.MAN))
	install -D -m0600 $^ $@

$(PREFIX)/$(LIB.H): libldif/$(notdir $(LIB.H))
	install -D -m0600 $^ $@

# static version for debugging
sldifanon: main.c $(addprefix libldif/,parse.o scan.o)
	$(CC) -o $@ $(CPPFLAGS) -Ilibldif $(CFLAGS) $^  -lsqlite3

ldifanon: main.c
	$(CC) -o $@ $(CPPFLAGS) -Ilibldif $(CFLAGS) $^ $(LDFLAGS) $(LDLIBS)

libldif/libldif.so: $(addprefix libldif/,parse.o scan.o)
	$(CC) -o $@ -shared $(CPPFLAGS) $(CFLAGS) $^ 

libldif/parse.c : $(PARSE.Y)
	$(YACC) -o $@ $(YFLAGS) $<

libldif/parse.yy : libldif/parse.y
	@$(YYGEN) $^ > $@~ &&  mv $@~ $@

libldif/scan.c : libldif/scan.l
	$(LEX) -o $@ $(LFLAGS) $^


libldif/parse.c: libldif/libldif.h

cscope.files:
	ls main.c $(addprefix libldif/,libldif.h parse.y scan.l) > $@

tags: TAGS
TAGS: $(shell test -r cscope.files && cat cscope.files)
	etags $^

####

try: t/try
	$^ < t/data

t/try: t/lex-try.o
	$(CC) -o $@ $^ -lfl
