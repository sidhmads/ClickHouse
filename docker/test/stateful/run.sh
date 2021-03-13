#!/bin/bash

set -e -x

dpkg -i package_folder/clickhouse-common-static_*.deb;
dpkg -i package_folder/clickhouse-common-static-dbg_*.deb
dpkg -i package_folder/clickhouse-server_*.deb
dpkg -i package_folder/clickhouse-client_*.deb
dpkg -i package_folder/clickhouse-test_*.deb

# install test configs
/usr/share/clickhouse-test/config/install.sh

function start()
{
    if [[ -n "$USE_DATABASE_REPLICATED" ]] && [[ "$USE_DATABASE_REPLICATED" -eq 1 ]]; then
        sudo -E -u clickhouse /usr/bin/clickhouse-server --config /etc/clickhouse-server2/config.xml --daemon \
        -- --path /var/lib/clickhouse2/ --logger.stderr /var/log/clickhouse-server/stderr2.log \
        --logger.log /var/log/clickhouse-server/clickhouse-server2.log --logger.errorlog /var/log/clickhouse-server/clickhouse-server2.err.log \
        --tcp_port 19000 --tcp_port_secure 19440 --http_port 18123 --https_port 18443 --interserver_http_port 19009 --tcp_with_proxy_port 19010 \
        --mysql_port 19004 \
        --test_keeper_server.tcp_port 19181 --test_keeper_server.server_id 2

        sudo -E -u clickhouse /usr/bin/clickhouse-server --config /etc/clickhouse-server3/config.xml --daemon \
        -- --path /var/lib/clickhouse3/ --logger.stderr /var/log/clickhouse-server/stderr3.log \
        --logger.log /var/log/clickhouse-server/clickhouse-server3.log --logger.errorlog /var/log/clickhouse-server/clickhouse-server3.err.log \
        --tcp_port 29000 --tcp_port_secure 29440 --http_port 28123 --https_port 28443 --interserver_http_port 29009 --tcp_with_proxy_port 29010 \
        --mysql_port 29004 \
        --test_keeper_server.tcp_port 29181 --test_keeper_server.server_id 3
    fi

    counter=0
    until clickhouse-client --query "SELECT 1"
    do
        if [ "$counter" -gt 120 ]
        then
            echo "Cannot start clickhouse-server"
            cat /var/log/clickhouse-server/stdout.log
            tail -n1000 /var/log/clickhouse-server/stderr.log
            tail -n1000 /var/log/clickhouse-server/clickhouse-server.log
            break
        fi
        timeout 120 service clickhouse-server start
        sleep 0.5
        counter=$((counter + 1))
    done
}

start
# shellcheck disable=SC2086 # No quotes because I want to split it into words.
/s3downloader --dataset-names $DATASETS
chmod 777 -R /var/lib/clickhouse
clickhouse-client --query "SHOW DATABASES"
clickhouse-client --query "ATTACH DATABASE datasets ENGINE = Ordinary"
clickhouse-client --query "CREATE DATABASE test"

service clickhouse-server restart

# Wait for server to start accepting connections
for _ in {1..120}; do
    clickhouse-client --query "SELECT 1" && break
    sleep 1
done

clickhouse-client --query "SHOW TABLES FROM datasets"
clickhouse-client --query "SHOW TABLES FROM test"
clickhouse-client --query "RENAME TABLE datasets.hits_v1 TO test.hits"
clickhouse-client --query "RENAME TABLE datasets.visits_v1 TO test.visits"
clickhouse-client --query "SHOW TABLES FROM test"

if grep -q -- "--use-skip-list" /usr/bin/clickhouse-test ; then
    SKIP_LIST_OPT="--use-skip-list"
fi

# We can have several additional options so we path them as array because it's
# more idiologically correct.
read -ra ADDITIONAL_OPTIONS <<< "${ADDITIONAL_OPTIONS:-}"

if [[ -n "$USE_DATABASE_REPLICATED" ]] && [[ "$USE_DATABASE_REPLICATED" -eq 1 ]]; then
    ADDITIONAL_OPTIONS+=('--replicated-database')
fi

clickhouse-test --testname --shard --zookeeper --no-stateless --hung-check --print-time "$SKIP_LIST_OPT" "${ADDITIONAL_OPTIONS[@]}" "$SKIP_TESTS_OPTION" 2>&1 | ts '%Y-%m-%d %H:%M:%S' | tee test_output/test_result.txt

./process_functional_tests_result.py || echo -e "failure\tCannot parse results" > /test_output/check_status.tsv

pigz < /var/log/clickhouse-server/clickhouse-server.log > /test_output/clickhouse-server.log.gz ||:
mv /var/log/clickhouse-server/stderr.log /test_output/ ||:
if [[ -n "$WITH_COVERAGE" ]] && [[ "$WITH_COVERAGE" -eq 1 ]]; then
    tar -chf /test_output/clickhouse_coverage.tar.gz /profraw ||:
fi
if [[ -n "$USE_DATABASE_REPLICATED" ]] && [[ "$USE_DATABASE_REPLICATED" -eq 1 ]]; then
    pigz < /var/log/clickhouse-server/clickhouse-server2.log > /test_output/clickhouse-server2.log.gz ||:
    pigz < /var/log/clickhouse-server/clickhouse-server3.log > /test_output/clickhouse-server3.log.gz ||:
    mv /var/log/clickhouse-server/stderr2.log /test_output/ ||:
    mv /var/log/clickhouse-server/stderr3.log /test_output/ ||:
fi
