# Csync2 SSL Certificate Generation Guide

Csync2 uses SSL certificates for secure communication between nodes. This guide explains how to generate SSL certificates using three different methods: RSA, ECDSA, and Ed25519. Only Csync2 2.1.1 https://github.com/centminmod/csync2/tree/2.1 supports ECDSA and Ed25519 SSH key generation via `make`.

* [Prerequisites](#prerequisites)
* [Certificate Generation Options Via make command](#certificate-generation-options-via-make-command)
* [Manual Certificate Generation](#manual-certificate-generation)

## Prerequisites

- Ensure you have OpenSSL installed on your system.
- You should have administrative access to run make commands.

## Certificate Generation Options Via make command

### 1. RSA Certificate (Default)

To generate a standard RSA certificate:

```
make cert
```

This command will:
- Create a 1024-bit RSA key
- Generate a certificate signing request (CSR)
- Create a self-signed certificate valid for 600 days

Files generated:
- Private key: `/etc/csync2/csync2_ssl_key.pem`
- Certificate: `/etc/csync2/csync2_ssl_cert.pem`

### 2. ECDSA Certificate

For an ECDSA certificate using the NIST P-256 curve:

```
make cert-ecdsa
```

This command will:
- Create an ECDSA key using the prime256v1 curve
- Generate a CSR
- Create a self-signed certificate valid for 600 days

Files generated:
- Private key: `/etc/csync2/csync2_ssl_key.pem`
- Certificate: `/etc/csync2/csync2_ssl_cert.pem`

### 3. Ed25519 Certificate

For an Ed25519 certificate:

```
make cert-ed25519
```

This command will:
- Create an Ed25519 key
- Generate a CSR
- Create a self-signed certificate valid for 600 days

Files generated:
- Private key: `/etc/csync2/csync2_ssl_key.pem`
- Certificate: `/etc/csync2/csync2_ssl_cert.pem`

## Important Notes

1. All methods generate files with the same names. Generating a new certificate will overwrite any existing ones.

2. The certificate's Common Name (CN) should match the hostname of your Csync2 node.

3. These are self-signed certificates valid for 600 days. For production environments, consider using certificates signed by a trusted Certificate Authority.

4. Ensure all nodes in your Csync2 cluster use the same type of certificate for compatibility.

5. After generating new certificates, restart Csync2 on all nodes to apply the changes.

6. If you replace a node's certificate, you may need to update the certificate cache on other nodes:
   ```
   csync2 --rm-ssl-cert <replaced-node-hostname>
   ```

7. To view the details of a node's SSL certificate:
   ```
   csync2 --ls-ssl-cert <node-hostname>
   ```

## Security Considerations

- ECDSA and Ed25519 certificates offer better performance and security compared to RSA for the same key size.
- The RSA key size (1024 bits) used in the default method is considered weak by modern standards. For RSA, a key size of at least 2048 bits is recommended for better security.
- Always keep your private keys secure and limit access to the `/etc/csync2` directory.

## Manual Certificate Generation

If you prefer to generate certificates manually or need more control over the process, you can use OpenSSL directly. Here are the steps for each certificate type:

### 1. Manual RSA Certificate Generation

```bash
# Generate RSA private key
openssl genrsa -out /etc/csync2/csync2_ssl_key.pem 2048

# Create a Certificate Signing Request (CSR)
openssl req -new -key /etc/csync2/csync2_ssl_key.pem \
       -subj "/C=US/ST=State/L=City/O=Organization/OU=Department/CN=hostname.example.com" \
       -out /etc/csync2/csync2_ssl_cert.csr

# Generate self-signed certificate
openssl x509 -req -days 600 -in /etc/csync2/csync2_ssl_cert.csr \
    -signkey /etc/csync2/csync2_ssl_key.pem \
    -out /etc/csync2/csync2_ssl_cert.pem

chmod 600 /etc/csync2/csync2_ssl_key.pem
chmod 644 /etc/csync2/csync2_ssl_cert.pem

openssl x509 -in /etc/csync2/csync2_ssl_cert.pem -text -noout

# Remove the CSR file
rm /etc/csync2/csync2_ssl_cert.csr
```

Note: We use 2048 bits here for better security, unlike the 1024 bits in the make cert command.

### 2. Manual ECDSA Certificate Generation

```bash
# Generate ECDSA private key
openssl ecparam -genkey -name prime256v1 -out /etc/csync2/csync2_ssl_key.pem

# Create a Certificate Signing Request (CSR)
openssl req -new -key /etc/csync2/csync2_ssl_key.pem \
       -subj "/C=US/ST=State/L=City/O=Organization/OU=Department/CN=hostname.example.com" \
       -out /etc/csync2/csync2_ssl_cert.csr

# Generate self-signed certificate
openssl x509 -req -days 600 -in /etc/csync2/csync2_ssl_cert.csr \
    -signkey /etc/csync2/csync2_ssl_key.pem \
    -out /etc/csync2/csync2_ssl_cert.pem

chmod 600 /etc/csync2/csync2_ssl_key.pem
chmod 644 /etc/csync2/csync2_ssl_cert.pem

openssl x509 -in /etc/csync2/csync2_ssl_cert.pem -text -noout

# Remove the CSR file
rm /etc/csync2/csync2_ssl_cert.csr
```

### 3. Manual Ed25519 Certificate Generation

```bash
# Generate Ed25519 private key
openssl genpkey -algorithm ED25519 -out /etc/csync2/csync2_ssl_key.pem

# Create a Certificate Signing Request (CSR)
openssl req -new -key /etc/csync2/csync2_ssl_key.pem \
       -subj "/C=US/ST=State/L=City/O=Organization/OU=Department/CN=hostname.example.com" \
       -out /etc/csync2/csync2_ssl_cert.csr

# Generate self-signed certificate
openssl x509 -req -days 600 -in /etc/csync2/csync2_ssl_cert.csr \
    -signkey /etc/csync2/csync2_ssl_key.pem \
    -out /etc/csync2/csync2_ssl_cert.pem

chmod 600 /etc/csync2/csync2_ssl_key.pem
chmod 644 /etc/csync2/csync2_ssl_cert.pem

openssl x509 -in /etc/csync2/csync2_ssl_cert.pem -text -noout

# Remove the CSR file
rm /etc/csync2/csync2_ssl_cert.csr
```

After generating the certificates manually, you'll need to restart the Csync2 service for the changes to take effect.