REBAR3=./rebar3
all: run

run: compile
	erl -noshell -pa _build/default/lib/*/ebin/ -eval 'test:run().'

compile:
	$(REBAR3) compile
