// sign - Ed25519 signing for the launcher's file list (manifest.json), run on the server owner's machine.
//
//	sign keygen <key file>        new key (private, 0600); prints the public key
//	sign pub    <key file>        prints the public key (base64), baked into FangsCE.exe as main.pubKey
//	sign sign   <key file> <file> writes <file>.sig (base64 signature of the file's bytes)
//	sign verify <pubkey> <file>   checks <file>.sig
//
// The private key never goes to the server: whoever controls the server (or the network path to a player)
// can then at most break downloads, not push code to players.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strings"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "sign:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) < 2 {
		return errors.New("usage: sign keygen|pub <key> | sign <key> <file> | verify <pubkey> <file>")
	}
	switch args[0] {
	case "keygen":
		if _, err := os.Stat(args[1]); err == nil {
			return fmt.Errorf("%s exists; not overwriting a signing key", args[1])
		}
		_, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return err
		}
		if err := os.WriteFile(args[1], []byte(base64.StdEncoding.EncodeToString(priv.Seed())+"\n"), 0o600); err != nil {
			return err
		}
		fmt.Println(base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey)))
	case "pub":
		priv, err := loadKey(args[1])
		if err != nil {
			return err
		}
		fmt.Println(base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey)))
	case "sign":
		if len(args) < 3 {
			return errors.New("usage: sign sign <key> <file>")
		}
		priv, err := loadKey(args[1])
		if err != nil {
			return err
		}
		data, err := os.ReadFile(args[2])
		if err != nil {
			return err
		}
		sig := base64.StdEncoding.EncodeToString(ed25519.Sign(priv, data))
		return os.WriteFile(args[2]+".sig", []byte(sig+"\n"), 0o644)
	case "verify":
		if len(args) < 3 {
			return errors.New("usage: sign verify <pubkey> <file>")
		}
		pub, err := base64.StdEncoding.DecodeString(args[1])
		if err != nil || len(pub) != ed25519.PublicKeySize {
			return errors.New("bad public key")
		}
		data, err := os.ReadFile(args[2])
		if err != nil {
			return err
		}
		sigText, err := os.ReadFile(args[2] + ".sig")
		if err != nil {
			return err
		}
		sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sigText)))
		if err != nil || !ed25519.Verify(pub, data, sig) {
			return errors.New("signature does NOT match")
		}
		fmt.Println("signature ok")
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
	return nil
}

func loadKey(path string) (ed25519.PrivateKey, error) {
	text, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(text)))
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("%s is not a signing key", path)
	}
	return ed25519.NewKeyFromSeed(seed), nil
}
