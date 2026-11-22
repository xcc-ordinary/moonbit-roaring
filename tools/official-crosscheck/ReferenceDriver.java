// Hex-driven front end for the OFFICIAL Java RoaringBitmap implementation
// (org.roaringbitmap:RoaringBitmap — the library family that generated the
// official RoaringFormatSpec testdata). It exists so a separate OS process
// running the reference implementation can exchange freshly generated
// portable bytes with MoonBit's cmd/main, with no shared code between them.
//
// Commands (bytes travel as hex; values are unsigned 32-bit decimals):
//   decode <hex>                          print every value, one per line,
//                                         ascending
//   encode [--run-optimize] -             read values from stdin, print
//                                         portable hex
//   range [--run-optimize] <start> <end>  half-open [start, end), print
//                                         portable hex
//   reencode <hex>                        deserialize then serialize, print
//                                         hex
//
// Values are parsed and printed as unsigned: Java's int is signed, but the
// portable format's value space is the full 32 bits, so 4294967295 must
// survive the round trip instead of becoming -1.
//
// Errors go to stderr with a non-zero exit, so an orchestrator can tell a
// rejected bitmap from an empty one. Requires JDK 17+ (HexFormat).

import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.HexFormat;
import java.util.Scanner;
import org.roaringbitmap.RoaringBitmap;

public final class ReferenceDriver {
  private static final long MAX_U32 = 4294967295L;

  public static void main(String[] args) {
    try {
      if (args.length == 0) {
        throw new IllegalArgumentException("missing command");
      }
      switch (args[0]) {
        case "decode" -> decode(args[1]);
        case "encode" -> encode(args);
        case "range" -> range(args);
        case "reencode" -> reencode(args[1]);
        default -> throw new IllegalArgumentException("unknown command: " + args[0]);
      }
    } catch (Exception e) {
      System.err.println("error: " + e);
      System.exit(1);
    }
  }

  private static long parseUnsigned(String text) {
    long value = Long.parseLong(text);
    if (value < 0 || value > MAX_U32) {
      throw new IllegalArgumentException("value out of 32-bit range: " + text);
    }
    return value;
  }

  private static RoaringBitmap fromHex(String hex) throws IOException {
    RoaringBitmap bitmap = new RoaringBitmap();
    bitmap.deserialize(ByteBuffer.wrap(HexFormat.of().parseHex(hex)));
    return bitmap;
  }

  private static void printHex(RoaringBitmap bitmap) {
    ByteBuffer buffer = ByteBuffer.allocate(bitmap.serializedSizeInBytes());
    bitmap.serialize(buffer);
    System.out.println(HexFormat.of().formatHex(buffer.array()));
  }

  private static void decode(String hex) throws IOException {
    RoaringBitmap bitmap = fromHex(hex);
    bitmap.forEach((int value) -> System.out.println(Integer.toUnsignedString(value)));
  }

  private static void encode(String[] args) {
    boolean runOptimize = args.length > 1 && args[1].equals("--run-optimize");
    String source = args[runOptimize ? 2 : 1];
    if (!source.equals("-")) {
      throw new IllegalArgumentException("encode reads values from stdin (-)");
    }
    RoaringBitmap bitmap = new RoaringBitmap();
    Scanner scanner = new Scanner(System.in);
    while (scanner.hasNext()) {
      bitmap.add((int) parseUnsigned(scanner.next()));
    }
    scanner.close();
    if (runOptimize) {
      bitmap.runOptimize();
    }
    printHex(bitmap);
  }

  private static void range(String[] args) {
    boolean runOptimize = args.length > 1 && args[1].equals("--run-optimize");
    int offset = runOptimize ? 2 : 1;
    long start = parseUnsigned(args[offset]);
    long end = parseUnsigned(args[offset + 1]);
    RoaringBitmap bitmap = new RoaringBitmap();
    bitmap.add(start, end);
    if (runOptimize) {
      bitmap.runOptimize();
    }
    printHex(bitmap);
  }

  private static void reencode(String hex) throws IOException {
    printHex(fromHex(hex));
  }
}