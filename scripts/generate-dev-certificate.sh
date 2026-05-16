#!/bin/sh
DIR="$HOME/Library/Application Support/net.leuski.galley.localized"
mkdir -p "$DIR"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
-days 3650 -nodes \
-subj "/CN=Galley Server/OU=net.leuski.galley" \
-keyout "$DIR/server-key.pem" \
-out "$DIR/server-cert.pem"
chmod 600 "$DIR/server-key.pem"

