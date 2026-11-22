// Hex-driven front end for the OFFICIAL Go RoaringBitmap implementation
// (github.com/RoaringBitmap/roaring). It exists so a separate OS process
// running the reference implementation can exchange freshly generated
// portable bytes with MoonBit's cmd/main, with no shared code between them.
//
// Commands (bytes travel as hex; values are unsigned 32-bit decimals):
//
//	decode <hex>                          print every value, one per line,
//	                                      ascending
//	encode [--run-optimize] -             read values from stdin, print
//	                                      portable hex
//	range [--run-optimize] <start> <end>  half-open [start, end), print
//	                                      portable hex
//	reencode <hex>                        deserialize then serialize, print
//	                                      hex
//
// The protocol matches tools/official-crosscheck/ReferenceDriver.java, so the
// same orchestrator matrix runs against both reference implementations.
// WriteTo/FromBuffer are the library's RoaringFormatSpec-compatible portable
// codec. Errors go to stderr with a non-zero exit.
package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"

	"github.com/RoaringBitmap/roaring"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("missing command")
	}
	switch args[0] {
	case "decode":
		return decode(args[1])
	case "encode":
		return encode(args[1:])
	case "range":
		return rangeCmd(args[1:])
	case "reencode":
		return reencode(args[1])
	default:
		return fmt.Errorf("unknown command: %s", args[0])
	}
}

func parseU32(text string) (uint32, error) {
	v, err := strconv.ParseUint(text, 10, 32)
	if err != nil {
		return 0, fmt.Errorf("value out of 32-bit range: %s", text)
	}
	return uint32(v), nil
}

func fromHex(s string) (*roaring.Bitmap, error) {
	data, err := hex.DecodeString(s)
	if err != nil {
		return nil, err
	}
	rb := roaring.New()
	if _, err := rb.FromBuffer(data); err != nil {
		return nil, err
	}
	return rb, nil
}

func printHex(rb *roaring.Bitmap) error {
	var buf bytes.Buffer
	if _, err := rb.WriteTo(&buf); err != nil {
		return err
	}
	fmt.Println(hex.EncodeToString(buf.Bytes()))
	return nil
}

func decode(s string) error {
	rb, err := fromHex(s)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(os.Stdout)
	for _, v := range rb.ToArray() {
		fmt.Fprintln(w, v)
	}
	return w.Flush()
}

func encode(args []string) error {
	runOptimize := len(args) > 0 && args[0] == "--run-optimize"
	if runOptimize {
		args = args[1:]
	}
	if len(args) != 1 || args[0] != "-" {
		return fmt.Errorf("encode reads values from stdin (-)")
	}
	rb := roaring.New()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	scanner.Split(bufio.ScanWords)
	for scanner.Scan() {
		v, err := parseU32(scanner.Text())
		if err != nil {
			return err
		}
		rb.Add(v)
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if runOptimize {
		rb.RunOptimize()
	}
	return printHex(rb)
}

func rangeCmd(args []string) error {
	runOptimize := len(args) > 0 && args[0] == "--run-optimize"
	if runOptimize {
		args = args[1:]
	}
	if len(args) != 2 {
		return fmt.Errorf("range needs start and end")
	}
	start, err := strconv.ParseUint(args[0], 10, 32)
	if err != nil {
		return fmt.Errorf("value out of 32-bit range: %s", args[0])
	}
	end, err := strconv.ParseUint(args[1], 10, 32)
	if err != nil {
		return fmt.Errorf("value out of 32-bit range: %s", args[1])
	}
	rb := roaring.New()
	rb.AddRange(start, end)
	if runOptimize {
		rb.RunOptimize()
	}
	return printHex(rb)
}

func reencode(s string) error {
	rb, err := fromHex(s)
	if err != nil {
		return err
	}
	return printHex(rb)
}