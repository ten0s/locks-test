REBAR3=./rebar3
all: run

run: compile
	erl -noshell -hidden -pa _build/default/lib/*/ebin/ _checkouts/*/ebin/ -eval 'test:run(investigate).'

run-heal: compile
	erl -noshell -hidden -pa _build/default/lib/*/ebin/ _checkouts/*/ebin/ -eval 'test:run(heal).'

upgrade:
	$(REBAR3) upgrade

compile:
	$(REBAR3) compile

clean:
	$(REBAR3) clean
