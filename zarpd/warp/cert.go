package warp

// The WARP/MASQUE handshake authenticates with a self-signed client certificate rather than a CA
// chain (the server pins the enrolled public key instead — see dial.go's tlsConfigFor). usque's
// own equivalents (GenerateEcKeyPair, GenerateCert) live in its internal package, which a
// different module can't import; these are small, standard uses of crypto/ecdsa and crypto/x509
// with no interesting design of their own; there's only really one reasonable way to write them.

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"math/big"
	"time"
)

// generateECKeyPair returns a new P-256 key pair, DER/PKIX-marshalled the way the WARP config
// file stores it (base64 of the private key, PEM of the public key elsewhere).
func generateECKeyPair() (priv *ecdsa.PrivateKey, privDER []byte, pubDER []byte, err error) {
	priv, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, nil, err
	}
	privDER, err = x509.MarshalECPrivateKey(priv)
	if err != nil {
		return nil, nil, nil, err
	}
	pubDER, err = x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		return nil, nil, nil, err
	}
	return priv, privDER, pubDER, nil
}

// generateSelfSignedCert makes a short-lived self-signed certificate for privKey. The server
// verifies the enrolled public key, not the certificate chain, so this only needs to be
// structurally valid, not signed by anyone in particular.
func generateSelfSignedCert(privKey *ecdsa.PrivateKey) ([][]byte, error) {
	cert, err := x509.CreateCertificate(rand.Reader, &x509.Certificate{
		SerialNumber: big.NewInt(0),
		NotBefore:    time.Now(),
		NotAfter:     time.Now().Add(24 * time.Hour),
	}, &x509.Certificate{}, &privKey.PublicKey, privKey)
	if err != nil {
		return nil, err
	}
	return [][]byte{cert}, nil
}
