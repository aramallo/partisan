PACKAGE         ?= partisan
VERSION         ?= $(shell git describe --tags)
BASE_DIR         = $(shell pwd)
ERLANG_BIN       = $(shell dirname $(shell which erl))
REBAR            = rebar3
MAKE			 = make
CONCURRENCY 	 ?= 4
LATENCY 		 ?= 0
SIZE 			 ?= 1024

.PHONY: rel deps test plots

all: compile

##
## Compilation targets
##

compile:
	$(REBAR) compile

clean: packageclean
	$(REBAR) clean

packageclean:
	rm -fr *.deb
	rm -fr *.tar.gz

##
## Test targets
##

proper:
	pkill -9 beam.smp; rm -rf priv/lager; ./rebar3 proper -m prop_partisan -p prop_sequential --noshrink -n 10

perf:
	pkill -9 beam.smp; pkill -9 epmd; SIZE=${SIZE} LATENCY=${LATENCY} CONCURRENCY=${CONCURRENCY} ${REBAR} ct --readable=false -v --suite=partisan_SUITE --case=performance_test --group=with_disterl
	pkill -9 beam.smp; pkill -9 epmd; SIZE=${SIZE} LATENCY=${LATENCY} CONCURRENCY=${CONCURRENCY} ${REBAR} ct --readable=false -v --suite=partisan_SUITE --case=performance_test --group=default
	pkill -9 beam.smp; pkill -9 epmd; SIZE=${SIZE} LATENCY=${LATENCY} CONCURRENCY=${CONCURRENCY} PARALLELISM=${CONCURRENCY} ${REBAR} ct --readable=false -v --suite=partisan_SUITE --case=performance_test --group=with_parallelism

kill: 
	pkill -9 beam.smp; pkill -9 epmd; exit 0

check: kill test xref dialyzer

test: ct eunit

lint:
	${REBAR} as lint lint

eunit:
	${REBAR} as test eunit

ct:
	openssl rand -out test/partisan_SUITE_data/RAND 4096
	${REBAR} ct -v --readable=false --suite=partisan_SUITE
	${REBAR} cover

shell:
	${REBAR} shell --apps partisan

tail-logs:
	tail ---disable-inotify -F priv/lager/*/log/*.log

unsorted-logs:
	cat priv/lager/*/log/*.log

logs:
	cat priv/lager/*/log/*.log | sort -k2M # -k3n -k4

##
## Release targets
##

rel:
	${REBAR} as test release

stage:
	${REBAR} as test release -d

DIALYZER_APPS = kernel stdlib erts sasl eunit syntax_tools compiler crypto

include tools.mk

## 
## Container targets
##

containerize-deps:
	docker build -f partisan-base.Dockerfile -t cmeiklejohn/partisan-base .

containerize-tests: containerize-deps
	docker build --no-cache -f partisan-test-suite.Dockerfile -t cmeiklejohn/partisan-test-suite .

containerize: containerize-deps
	docker build --no-cache -f Dockerfile -t cmeiklejohn/partisan .

compose: containerize
	docker-compose down; docker-compose rm; docker-compose up

##
## CI targets
##

verify-lampson-2pc: kill bin-perms compile
	make lampson-2pc | grep "Passed: 7, Failed: 1"

verify-bernstein-ctp: kill bin-perms compile
	make bernstein-ctp | grep "Passed: 11, Failed: 1"

verify-skeen-3pc: kill bin-perms compile
	make skeen-3pc | grep "Passed: 25, Failed: 1"

##
## Testing targets
##

make bin-perms:
	chmod 755 bin/*.sh
	chmod 755 bin/*.escript

demers-anti-entropy: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_reliable_broadcast RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=demers_anti_entropy SUBLIST=0 bin/check-model.sh

demers-rumor-mongering: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_reliable_broadcast RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=demers_rumor_mongering SUBLIST=0 bin/check-model.sh

demers-direct-mail-acked: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_reliable_broadcast RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=demers_direct_mail_acked SUBLIST=0 bin/check-model.sh

demers-direct-mail: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_reliable_broadcast RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=demers_direct_mail SUBLIST=0 bin/check-model.sh

lampson-2pc: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_reliable_broadcast RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=lampson_2pc SUBLIST=0 bin/check-model.sh

bernstein-ctp: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_reliable_broadcast RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=bernstein_ctp SUBLIST=0 bin/check-model.sh

skeen-3pc: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_reliable_broadcast RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=skeen_3pc SUBLIST=0 bin/check-model.sh

lampson-2pc-noise: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_reliable_broadcast EXIT_ON_COUNTEREXAMPLE=true NOISE=true RECURSIVE=false PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=lampson_2pc SUBLIST=0 bin/check-model.sh

paxoid: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_paxoid RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=paxoid SUBLIST=0 bin/check-paxoid.sh

lashup: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_lashup RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=lashup SUBLIST=0 bin/check-lashup.sh

zraft: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_zraft RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=zraft SUBLIST=0 bin/check-zraft.sh

hbbft: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_hbbft RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=hbbft SUBLIST=0 bin/check-hbbft.sh

alsberg-day: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_primary_backup RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=alsberg_day SUBLIST=0 bin/filibuster.sh

alsberg-day-acked: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_primary_backup RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=alsberg_day_acked SUBLIST=0 bin/filibuster.sh

alsberg-day-acked-membership: kill bin-perms compile
	SYSTEM_MODEL=prop_partisan_primary_backup RECURSIVE=true PRELOAD_SCHEDULES=false IMPLEMENTATION_MODULE=alsberg_day_acked_membership SUBLIST=0 bin/filibuster.sh
