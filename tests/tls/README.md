# Test certificates

Test-only keys and certificates for `tests/test_tls.nim`, valid until 2126. Never use them anywhere else.

- `rsa-cert.pem`, `rsa-key.pem`: a self-signed RSA CA for `localhost` and `127.0.0.1`, also served as a leaf.
- `ec-chain.pem`, `ec-key.pem`: an ECDSA P-256 leaf signed by that CA, followed by the CA (a full PEM chain).

They were made with OpenSSL 3:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout rsa-key.pem -out rsa-cert.pem -days 36500 \
  -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
  -addext basicConstraints=critical,CA:TRUE \
  -addext keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign
openssl ecparam -name prime256v1 -genkey -noout | openssl pkey -out ec-key.pem
openssl req -new -key ec-key.pem -subj /CN=localhost -out ec.csr
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n' > ec.ext
openssl x509 -req -in ec.csr -CA rsa-cert.pem -CAkey rsa-key.pem -set_serial 2 -days 36500 \
  -sha256 -extfile ec.ext -out ec-cert.pem
cat ec-cert.pem rsa-cert.pem > ec-chain.pem
```
