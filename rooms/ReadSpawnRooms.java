// Prints which buildings of map folders hold spawn points, read from the folders' cell headers
// (<x>_<y>.lotheader) as the game reads them (IsoMetaGrid's loadCell). A building holds a point when one
// of its rooms, other than "emptyoutside", has a rectangle with the point on the point's level, and the
// game files that room under the point's cell: the cell of the header, and in Build 42 also the cells east,
// south and south-east of the building's first cell when the building reaches past it
// (addRoomsToAdjacentCells). Build 41 files every room of the cell and the game takes the first one with
// the point, in file order, so a point counts there only when that room belongs to a building.
// Usage: java -jar read_spawn_rooms.jar <squares per cell: 256 (Build 42) or 300 (Build 41)> <map folder>...
// stdin: the points, "<x>\t<y>\t<z>" per line.
// stdout: "<folder>\t<x>\t<y>\t<z>\t<building x>\t<building y>" for each point and building of the folder
// that holds it, the building's x and y being the least of all its rooms' rectangles; for a cell header that
// can't be read, "!\t<folder>\t<file>\t<why>" once and, instead of buildings, "?\t<folder>\t<x>\t<y>\t<z>"
// for each point it could hold.

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class ReadSpawnRooms {
    private static final byte[] MAGIC = {'L', 'O', 'T', 'H'};

    private record Rect(int x, int y, int w, int h) {
        boolean contains(int px, int py) {
            return px >= x && py >= y && px < x + w && py < y + h;
        }
    }

    private static final class Room {
        final String name;
        final int level;
        final List<Rect> rects = new ArrayList<>();
        Building building;

        Room(String name, int level) {
            this.name = name;
            this.level = level;
        }

        boolean holds(int[] point) {
            return !"emptyoutside".equalsIgnoreCase(name) && level == point[2] && rects.stream().anyMatch(r -> r.contains(point[0], point[1]));
        }
    }

    private static final class Building {
        final List<Room> rooms = new ArrayList<>();
        int x = Integer.MAX_VALUE;
        int y = Integer.MAX_VALUE;

        // Whether the game files the building's rooms under this cell of 256 squares besides the cell of its
        // header: the cell east, south or south-east of its first cell. (It does when the building reaches past
        // that one, which a building holding a point there does.)
        boolean spillsInto(int cellX, int cellY) {
            int dx = cellX - x / 256;
            int dy = cellY - y / 256;
            return dx >= 0 && dx <= 1 && dy >= 0 && dy <= 1 && dx + dy > 0;
        }
    }

    // A cell header that can't be read has neither.
    private record Cell(List<Room> rooms, List<Building> buildings) {}

    private static final Cell UNREADABLE = new Cell(List.of(), List.of());

    public static void main(String[] args) throws IOException {
        if (args.length < 1 || !(args[0].equals("256") || args[0].equals("300"))) {
            System.err.println("usage: read_spawn_rooms.jar <256 or 300> <map folder>...");
            System.exit(2);
        }
        int size = Integer.parseInt(args[0]);
        List<int[]> points = new ArrayList<>();
        try (BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
            for (String line; (line = in.readLine()) != null; ) {
                if (line.isEmpty()) continue;
                String[] parts = line.split("\t");
                if (parts.length != 3) {
                    System.err.println("not a point: " + line);
                    System.exit(2);
                }
                points.add(new int[] {Integer.parseInt(parts[0]), Integer.parseInt(parts[1]), Integer.parseInt(parts[2])});
            }
        }
        PrintWriter out = new PrintWriter(new BufferedWriter(new OutputStreamWriter(System.out, StandardCharsets.UTF_8)));
        for (int a = 1; a < args.length; a++) {
            String folder = args[a];
            Map<String, Cell> cells = new HashMap<>();
            for (int[] point : points) {
                int cellX = Math.floorDiv(point[0], size);
                int cellY = Math.floorDiv(point[1], size);
                List<Building> holding = new ArrayList<>();
                boolean unknown = false;
                // The point's cell, then in Build 42 the cells west, north and north-west of it.
                for (int[] at : size == 300 ? new int[][] {{0, 0}} : new int[][] {{0, 0}, {-1, 0}, {0, -1}, {-1, -1}}) {
                    Cell cell = cell(out, cells, folder, cellX + at[0], cellY + at[1], size);
                    if (cell == null) continue;
                    if (cell == UNREADABLE) {
                        unknown = true;
                    } else if (size == 300) {
                        Room first = cell.rooms.stream().filter(r -> r.holds(point)).findFirst().orElse(null);
                        if (first != null && first.building != null) holding.add(first.building);
                    } else {
                        boolean own = at[0] == 0 && at[1] == 0;
                        for (Building building : cell.buildings) {
                            if ((own || building.spillsInto(cellX, cellY)) && building.rooms.stream().anyMatch(r -> r.holds(point))) holding.add(building);
                        }
                    }
                }
                if (unknown) {
                    out.println("?\t" + folder + "\t" + point[0] + "\t" + point[1] + "\t" + point[2]);
                } else {
                    for (Building building : holding) print(out, folder, point, building);
                }
            }
        }
        out.flush();
        if (out.checkError()) System.exit(1);
    }

    // The cell header of a folder, read once: null when there is none, UNREADABLE when it can't be read.
    private static Cell cell(PrintWriter out, Map<String, Cell> cells, String folder, int cellX, int cellY, int size) {
        String name = cellX + "_" + cellY + ".lotheader";
        if (!cells.containsKey(name)) {
            Path file = Path.of(folder, name);
            Cell cell = null;
            if (Files.isRegularFile(file)) {
                try {
                    cell = read(file, cellX, cellY, size);
                } catch (IOException | RuntimeException e) {
                    out.println("!\t" + folder + "\t" + name + "\t" + e);
                    cell = UNREADABLE;
                }
            }
            cells.put(name, cell);
        }
        return cells.get(name);
    }

    private static void print(PrintWriter out, String folder, int[] point, Building building) {
        out.println(folder + "\t" + point[0] + "\t" + point[1] + "\t" + point[2] + "\t" + building.x + "\t" + building.y);
    }

    private static Cell read(Path file, int cellX, int cellY, int size) throws IOException {
        boolean build42 = size == 256;
        try (DataInputStream in = new DataInputStream(new BufferedInputStream(Files.newInputStream(file), 1 << 16))) {
            // Build 42 takes the magic as optional; Build 41 has none.
            if (build42) {
                in.mark(MAGIC.length);
                if (!Arrays.equals(in.readNBytes(MAGIC.length), MAGIC)) in.reset();
            }
            int version = readInt(in);
            if (build42 && (version < 0 || version > 1)) throw new IOException("unsupported version " + version);
            int tiles = count(in);
            for (int i = 0; i < tiles; i++) readLine(in);
            boolean oldLayout = !build42 || version == 0;
            if (oldLayout) in.readByte();
            int width = readInt(in);
            int height = readInt(in);
            if (build42 && (width != 8 || height != 8)) throw new IOException("invalid chunk width " + width + "x" + height);
            readInt(in);
            if (!oldLayout) readInt(in);
            List<Room> rooms = new ArrayList<>();
            for (int i = count(in); i > 0; i--) {
                Room room = new Room(readLine(in), readInt(in));
                for (int r = count(in); r > 0; r--) {
                    room.rects.add(new Rect(readInt(in) + cellX * size, readInt(in) + cellY * size, readInt(in), readInt(in)));
                }
                in.skipNBytes(12L * count(in));
                rooms.add(room);
            }
            List<Building> buildings = new ArrayList<>();
            for (int i = count(in); i > 0; i--) {
                Building building = new Building();
                for (int r = count(in); r > 0; r--) {
                    int index = readInt(in);
                    if (index < 0 || index >= rooms.size()) throw new IOException("room " + index + " of " + rooms.size());
                    Room room = rooms.get(index);
                    room.building = building;
                    building.rooms.add(room);
                    for (Rect rect : room.rects) {
                        building.x = Math.min(building.x, rect.x());
                        building.y = Math.min(building.y, rect.y());
                    }
                }
                buildings.add(building);
            }
            return new Cell(rooms, buildings);
        }
    }

    private static int readInt(DataInputStream in) throws IOException {
        return Integer.reverseBytes(in.readInt());
    }

    private static int count(DataInputStream in) throws IOException {
        int n = readInt(in);
        if (n < 0) throw new IOException("negative count " + n);
        return n;
    }

    // Like the game's BufferedRandomAccessFile.getNextLine: up to a newline, without a carriage return before it.
    private static String readLine(DataInputStream in) throws IOException {
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        for (int c; (c = in.read()) != '\n'; ) {
            if (c < 0) throw new EOFException();
            line.write(c);
        }
        byte[] bytes = line.toByteArray();
        int length = bytes.length > 0 && bytes[bytes.length - 1] == '\r' ? bytes.length - 1 : bytes.length;
        return new String(bytes, 0, length, StandardCharsets.UTF_8);
    }
}
