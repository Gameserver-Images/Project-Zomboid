// Prints the version of the installed game as the server logs it (major.minor.build), read from
// zombie/core/Core.class without loading any game class: the GameVersion its static initializer
// creates for gameVersion, and the constant buildVersion. Otherwise prints why on stderr and exits
// with 1.
// Usage: java -jar read_game_version.jar <classpath entry>...

import java.io.ByteArrayInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

public final class ReadGameVersion {
    private static final String CORE = "zombie/core/Core.class";

    private static final class Failure extends Exception {
        Failure(String message) {
            super(message);
        }
    }

    public static void main(String[] args) {
        try {
            System.out.println(read(find(args)));
        } catch (Failure e) {
            System.err.println(e.getMessage());
            System.exit(1);
        } catch (IOException | RuntimeException e) {
            System.err.println(CORE + " could not be read: " + e);
            System.exit(1);
        }
    }

    // The first classpath entry that has the class, like the JVM.
    private static byte[] find(String[] classpath) throws Failure, IOException {
        for (String entry : classpath) {
            Path path = Path.of(entry);
            if (Files.isDirectory(path)) {
                Path file = path.resolve(CORE);
                if (Files.isRegularFile(file)) {
                    return Files.readAllBytes(file);
                }
            } else if (Files.isRegularFile(path)) {
                ZipFile jar;
                try {
                    jar = new ZipFile(path.toFile());
                } catch (IOException e) {
                    // The JVM skips a jar it can't open.
                    continue;
                }
                try (jar) {
                    ZipEntry zipEntry = jar.getEntry(CORE);
                    if (zipEntry != null) {
                        try (InputStream in = jar.getInputStream(zipEntry)) {
                            return in.readAllBytes();
                        }
                    }
                }
            }
        }
        throw new Failure("no entry of the game's classpath (" + String.join(" ", classpath) + ") holds " + CORE);
    }

    private static String read(byte[] bytes) throws Failure, IOException {
        ClassFile core = new ClassFile(bytes);
        int build = core.buildVersion();
        int[] version = core.gameVersion();
        return version[0] + "." + version[1] + "." + build;
    }

    private static final class ClassFile {
        private final DataInputStream in;
        private final int[] tags;
        private final String[] utf8;
        private final int[] ints;
        private final int[] first;
        private final int[] second;
        private Integer buildVersion;
        private byte[] clinit;

        ClassFile(byte[] bytes) throws Failure, IOException {
            in = new DataInputStream(new ByteArrayInputStream(bytes));
            if (in.readInt() != 0xCAFEBABE) {
                throw new Failure(CORE + " is not a class file");
            }
            in.readUnsignedShort();
            in.readUnsignedShort();
            int count = in.readUnsignedShort();
            tags = new int[count];
            utf8 = new String[count];
            ints = new int[count];
            first = new int[count];
            second = new int[count];
            for (int i = 1; i < count; i++) {
                tags[i] = in.readUnsignedByte();
                switch (tags[i]) {
                    case 1 -> utf8[i] = in.readUTF();
                    case 3 -> ints[i] = in.readInt();
                    case 4 -> in.readInt();
                    case 5, 6 -> {
                        in.readLong();
                        i++;
                    }
                    case 7, 8, 16, 19, 20 -> first[i] = in.readUnsignedShort();
                    case 9, 10, 11, 12, 17, 18 -> {
                        first[i] = in.readUnsignedShort();
                        second[i] = in.readUnsignedShort();
                    }
                    case 15 -> {
                        in.readUnsignedByte();
                        first[i] = in.readUnsignedShort();
                    }
                    default -> throw new Failure(CORE + " has an unknown constant pool entry of type " + tags[i]);
                }
            }
            in.readUnsignedShort();
            in.readUnsignedShort();
            in.readUnsignedShort();
            in.skipNBytes(2L * in.readUnsignedShort());
            int fields = in.readUnsignedShort();
            for (int i = 0; i < fields; i++) {
                member(false);
            }
            int methods = in.readUnsignedShort();
            for (int i = 0; i < methods; i++) {
                member(true);
            }
        }

        // A field or method: keeps the constant of buildVersion and the code of <clinit>.
        private void member(boolean method) throws IOException {
            in.readUnsignedShort();
            String name = utf8[in.readUnsignedShort()];
            String descriptor = utf8[in.readUnsignedShort()];
            int attributes = in.readUnsignedShort();
            for (int i = 0; i < attributes; i++) {
                String attribute = utf8[in.readUnsignedShort()];
                int length = in.readInt();
                if (!method && "buildVersion".equals(name) && "I".equals(descriptor) && "ConstantValue".equals(attribute)) {
                    int index = in.readUnsignedShort();
                    if (tags[index] == 3) {
                        buildVersion = ints[index];
                    }
                } else if (method && "<clinit>".equals(name) && "Code".equals(attribute)) {
                    in.readUnsignedShort();
                    in.readUnsignedShort();
                    clinit = new byte[in.readInt()];
                    in.readFully(clinit);
                    in.skipNBytes(length - 8L - clinit.length);
                } else {
                    in.skipNBytes(length);
                }
            }
        }

        int buildVersion() throws Failure {
            if (buildVersion == null) {
                throw new Failure(CORE + " has no int constant buildVersion");
            }
            return buildVersion;
        }

        // In <clinit>: push major, push minor, push suffix, invokespecial GameVersion.<init>(IILjava/lang/String;)V,
        // putstatic Core.gameVersion.
        int[] gameVersion() throws Failure {
            if (clinit == null) {
                throw new Failure(CORE + " has no static initializer");
            }
            int[] starts = new int[4];
            int seen = 0;
            for (int pc = 0; pc < clinit.length; pc += length(pc)) {
                int op = clinit[pc] & 0xFF;
                if (op == 0xB7 && seen >= 3 && isMember(u2(pc + 1), 10, "zombie/core/GameVersion", "<init>", "(IILjava/lang/String;)V")) {
                    int next = pc + 3;
                    Integer major = intPush(starts[2]);
                    Integer minor = intPush(starts[1]);
                    if (next < clinit.length && (clinit[next] & 0xFF) == 0xB3
                        && isMember(u2(next + 1), 9, "zombie/core/Core", "gameVersion", "Lzombie/core/GameVersion;")
                        && major != null && minor != null && isStringPush(starts[0])) {
                        return new int[] {major, minor};
                    }
                }
                System.arraycopy(starts, 0, starts, 1, 3);
                starts[0] = pc;
                seen++;
            }
            throw new Failure("the static initializer of " + CORE + " sets gameVersion to no new GameVersion(<major>, <minor>, <suffix>)");
        }

        private boolean isMember(int index, int tag, String owner, String name, String descriptor) {
            return descriptor.equals(descriptorOf(index, tag)) && owner.equals(utf8[first[first[index]]])
                && name.equals(utf8[first[second[index]]]);
        }

        // The descriptor of the field or method that the constant at index refers to, when it has that tag.
        private String descriptorOf(int index, int tag) {
            return index > 0 && index < tags.length && tags[index] == tag ? utf8[second[second[index]]] : null;
        }

        private Integer intPush(int pc) {
            int op = clinit[pc] & 0xFF;
            if (op >= 0x02 && op <= 0x08) {
                return op - 0x03;
            }
            return switch (op) {
                case 0x10 -> (int) clinit[pc + 1];
                case 0x11 -> (int) (short) u2(pc + 1);
                case 0x12 -> constantInt(clinit[pc + 1] & 0xFF);
                case 0x13 -> constantInt(u2(pc + 1));
                default -> null;
            };
        }

        private Integer constantInt(int index) {
            return index < tags.length && tags[index] == 3 ? ints[index] : null;
        }

        // One instruction that pushes the suffix without taking anything from the stack, so that the two
        // before it push major and minor: null, a string constant, a local, a static field or a static
        // method without arguments.
        private boolean isStringPush(int pc) {
            int op = clinit[pc] & 0xFF;
            return switch (op) {
                case 0x01, 0x19, 0x2A, 0x2B, 0x2C, 0x2D -> true;
                case 0x12 -> isString(clinit[pc + 1] & 0xFF);
                case 0x13 -> isString(u2(pc + 1));
                case 0xB2 -> "Ljava/lang/String;".equals(descriptorOf(u2(pc + 1), 9));
                case 0xB8 -> "()Ljava/lang/String;".equals(descriptorOf(u2(pc + 1), 10))
                    || "()Ljava/lang/String;".equals(descriptorOf(u2(pc + 1), 11));
                default -> false;
            };
        }

        private boolean isString(int index) {
            return index < tags.length && tags[index] == 8;
        }

        private int u2(int pc) {
            return (clinit[pc] & 0xFF) << 8 | clinit[pc + 1] & 0xFF;
        }

        private int s4(int pc) {
            return u2(pc) << 16 | u2(pc + 2);
        }

        // The length of the instruction at pc (JVMS 6.5).
        private int length(int pc) {
            int op = clinit[pc] & 0xFF;
            switch (op) {
                case 0x10, 0x12, 0x15, 0x16, 0x17, 0x18, 0x19, 0x36, 0x37, 0x38, 0x39, 0x3A, 0xA9, 0xBC:
                    return 2;
                case 0x11, 0x13, 0x14, 0x84, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xBB, 0xBD, 0xC0, 0xC1, 0xC6, 0xC7:
                    return 3;
                case 0xC5:
                    return 4;
                case 0xB9, 0xBA, 0xC8, 0xC9:
                    return 5;
                case 0xC4:
                    return (clinit[pc + 1] & 0xFF) == 0x84 ? 6 : 4;
                case 0xAA: {
                    int at = pc + 1 + (3 - pc % 4);
                    return at - pc + 12 + 4 * (s4(at + 8) - s4(at + 4) + 1);
                }
                case 0xAB: {
                    int at = pc + 1 + (3 - pc % 4);
                    return at - pc + 8 + 8 * s4(at + 4);
                }
                default:
                    return op >= 0x99 && op <= 0xA8 ? 3 : 1;
            }
        }
    }
}
