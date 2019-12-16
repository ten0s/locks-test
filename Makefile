REBAR3=./rebar3
all: run

run: compile
	erl -noshell -hidden -pa _build/default/lib/*/ebin/ -eval 'test:run().'

upgrade:
	$(REBAR3) upgrade

compile:
	$(REBAR3) compile

clean:
	$(REBAR3) clean
