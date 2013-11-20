#!/usr/bin/env bash

DOBENCHMARK=0
BENCHMARKITER=30
OPENSSLBIN="./openssl"
#OPENSSLBIN="/usr/bin/openssl"
TIMEOUT=10
CIPHERSUITE="ALL:COMPLEMENTOFALL"
REQUEST="GET / HTTP/1.1
Host: $TARGET


"


verbose() {
    if [ $VERBOSE -eq 1 ];then
        echo $@
    fi
}


# Connect to a target host with the selected ciphersuite
test_cipher_on_target() {
    local sslcommand=$@
    cipher=""
    protocols=""
    pfs=""
    for tls_version in "-ssl2" "-ssl3" "-tls1" "-tls1_1" "-tls1_2"
    do
        local tmp=$(mktemp)
        $sslcommand $tls_version 1>"$tmp" 2>/dev/null << EOF
$REQUEST
EOF
        current_cipher=$(grep "New, " $tmp|awk '{print $5}')
        current_pfs=$(grep 'Server Temp Key' $tmp|awk '{print $4$5$6$7}')
        current_protocol=$(grep -E "^\s+Protocol\s+:" $tmp|awk '{print $3}')
        if [[ -z "$current_protocol" || "$current_cipher" == '(NONE)' ]]; then
            # connection failed, try again with next TLS version
            continue
        fi
        # connection succeeded, add TLS version to positive results
        if [ -z "$protocols" ]; then
            protocols=$current_protocol
        else
            protocols="$protocols,$current_protocol"
        fi
        cipher=$current_cipher
        pfs=$current_pfs
        # grab the cipher and PFS key size
        rm "$tmp"
    done
    # if cipher is empty, that means none of the TLS version worked with
    # the current cipher
    if [ -z "$cipher" ]; then
        verbose "handshake failed, no ciphersuite was returned"
        result='ConnectionFailure'
        return 2

    # if cipher contains NONE, the cipher wasn't accepted
    elif [ "$cipher" == '(NONE)  ' ]; then
        result="$cipher $protocols $pfs"
        verbose "handshake failed, server returned ciphersuite '$result'"
        return 1

    # the connection succeeded
    else
        result="$cipher $protocols $pfs"
        verbose "handshake succeeded, server returned ciphersuite '$result'"
        return 0
    fi
}


# Calculate the average handshake time for a specific ciphersuite
bench_cipher() {
    local ciphersuite="$1"
    local sslcommand="timeout $TIMEOUT $OPENSSLBIN s_client -connect $TARGET -cipher $ciphersuite"
    local t="$(date +%s%N)"
    verbose "Benchmarking handshake on '$TARGET' with ciphersuite '$ciphersuite'"
    for i in $(seq 1 $BENCHMARKITER); do
        $sslcommand 2>/dev/null 1>/dev/null << EOF
$REQUEST
EOF
        if [ $? -gt 0 ]; then
            break
        fi
    done
    # Time interval in nanoseconds
    local t="$(($(date +%s%N) - t))"
    verbose "Benchmarking done in $t nanoseconds"
    # Microseconds
    cipherbenchms="$((t/1000/$BENCHMARKITER))"
}


# Connect to the target and retrieve the chosen cipher
# recursively until the connection fails
get_cipher_pref() {
    local ciphersuite="$1"
    local sslcommand="timeout $TIMEOUT $OPENSSLBIN s_client -connect $TARGET -cipher $ciphersuite"
    verbose "Connecting to '$TARGET' with ciphersuite '$ciphersuite'"
    test_cipher_on_target "$sslcommand"
    local success=$?
    # If the connection succeeded with the current cipher, benchmark and store
    if [ $success -eq 0 ]; then
        cipherspref=("${cipherspref[@]}" "$result")
        pciph=$(echo $result|awk '{print $1}')
        get_cipher_pref "!$pciph:$ciphersuite"
        return 0
    fi
}


if [ -z $1 ]; then
    echo "
usage: $0 <target:port> <-v>

$0 attempts to connect to a target site using all the ciphersuites it knowns.
jvehent - ulfr -  2013
"
    exit 1
fi
TARGET=$1
VERBOSE=0
ALLCIPHERS=0
if [ ! -z $2 ]; then
    if [ "$2" == "-v" ]; then
        VERBOSE=1
        echo "Loading $($OPENSSLBIN ciphers -v $CIPHERSUITE 2>/dev/null|grep Kx|wc -l) ciphersuites from $(echo -n $($OPENSSLBIN version 2>/dev/null))"
        $OPENSSLBIN ciphers ALL 2>/dev/null
    fi
    if [ "$2" == "-a" ]; then
        ALLCIPHERS=1
    fi
fi

cipherspref=();
results=()

# Call to the recursive loop that retrieves the cipher preferences
get_cipher_pref $CIPHERSUITE

# Display the results
ctr=1
for cipher in "${cipherspref[@]}"; do
    pciph=$(echo $cipher|awk '{print $1}')
    if [ $DOBENCHMARK -eq 1 ]; then
        bench_cipher "$pciph"
        r="$ctr $cipher $cipherbenchms"
    else
        r="$ctr $cipher"
    fi
    results=("${results[@]}" "$r")
    ctr=$((ctr+1))
done

if [ $DOBENCHMARK -eq 1 ]; then
    header="prio ciphersuite protocols pfs_keysize avg_handshake_microsec"
else
    header="prio ciphersuite protocols pfs_keysize"
fi
ctr=0
for result in "${results[@]}"; do
    if [ $ctr -eq 0 ]; then
        echo $header
        ctr=$((ctr+1))
    fi
    echo $result|grep -v '(NONE)'
done|column -t

if [ $ALLCIPHERS -gt 0 ]; then
    echo; echo "All accepted ciphersuites"
    for cipher in $($OPENSSLBIN ciphers -v ALL:COMPLEMENTOFALL 2>/dev/null |awk '{print $1}'|sort|uniq); do
        osslcommand="timeout $TIMEOUT $OPENSSLBIN s_client -connect $TARGET -cipher $cipher"
        test_cipher_on_target "$osslcommand"
        r=$?
        if [ $r -eq 0 ]; then
            echo -en '\E[40;32m'"OK"; tput sgr0
        else
            echo -en '\E[40;31m'"KO"; tput sgr0
        fi
        echo " $cipher"
    done
fi
