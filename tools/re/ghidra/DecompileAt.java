// Decompile chosen functions of a program imported without auto-analysis (tools/re/decomp.sh).
// Args: <out dir> <depth> <target>...
//   target = 0x<VA> (any address inside a function: its start comes from .pdata)
//          | <UFUNCTION name> (resolved through UHT's FNameNativePtrPair tables to the exec thunk, like natives.py)
//   depth  = also decompile the direct callees, this many levels down (at most 64 functions per run)
// Writes <label>_<address>.c per function and targets.json (one row per function, ok/failed counts).
//@category FangsCE
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.cmd.function.CreateFunctionCmd;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.scalar.Scalar;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public class DecompileAt extends GhidraScript {
    static final int MAX_FUNCTIONS = 64;
    Path out;
    DecompInterface dec;
    final List<String> rows = new ArrayList<>();
    final Set<Address> done = new HashSet<>();
    int ok = 0, failed = 0;

    static String q(String s) {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ").replace("\r", " ") + "\"";
    }

    void record(String label, String target, String status, String file, String msg) {
        rows.add("{\"label\":" + q(label) + ",\"target\":" + q(target) + ",\"status\":" + q(status)
            + ",\"file\":" + q(file) + ",\"message\":" + q(msg) + "}");
    }

    // Exec thunks registered for a UFUNCTION name: {const char* name; FNativeFuncPtr thunk} pairs.
    List<Address> thunksFor(String name) throws Exception {
        Memory mem = currentProgram.getMemory();
        byte[] pat = (name + "\0").getBytes(StandardCharsets.US_ASCII);
        List<Address> res = new ArrayList<>();
        for (Address a = mem.findBytes(mem.getMinAddress(), pat, null, true, monitor); a != null;
             a = mem.findBytes(a.add(1), pat, null, true, monitor)) {
            if (mem.getByte(a.subtract(1)) != 0) continue;
            long va = a.getOffset();
            byte[] ptr = new byte[8];
            for (int i = 0; i < 8; i++) ptr[i] = (byte) (va >>> (8 * i));
            for (Address p = mem.findBytes(mem.getMinAddress(), ptr, null, true, monitor); p != null;
                 p = mem.findBytes(p.add(1), ptr, null, true, monitor)) {
                Address fn;
                try {
                    fn = toAddr(mem.getLong(p.add(8)));
                } catch (Exception e) {
                    continue;   // pointer at the end of a block: not a pair
                }
                MemoryBlock b = mem.getBlock(fn);
                if (b == null || !b.isExecute() || res.contains(fn)) continue;
                if (isNextConstructGetter(fn, p)) {
                    println(name + ": skipped " + fn + ", the construct getter of the next table entry");
                    continue;
                }
                res.add(fn);
            }
        }
        return res;
    }

    // Start of the function containing a, from the x64 exception table (.pdata: begin, end, unwind RVAs).
    Address pdataStart(Address a) throws Exception {
        MemoryBlock pd = currentProgram.getMemory().getBlock(".pdata");
        if (pd == null) return a;
        long base = currentProgram.getImageBase().getOffset(), rva = a.getOffset() - base;
        long lo = 0, hi = pd.getSize() / 12 - 1;
        while (lo <= hi) {
            long mid = (lo + hi) / 2;
            Address e = pd.getStart().add(mid * 12);
            long begin = getInt(e) & 0xffffffffL, end = getInt(e.add(4)) & 0xffffffffL;
            if (rva < begin) hi = mid - 1;
            else if (rva >= end) lo = mid + 1;
            else return toAddr(base + begin);
        }
        return a;
    }

    // Disassemble first, then (re)compute the body: a function made before its code was disassembled keeps an
    // empty body, and the decompiler hides that by following the code itself.
    Function ensure(Address a) throws Exception {
        Address start = pdataStart(a);
        if (getInstructionAt(start) == null && !disassemble(start)) {
            throw new IllegalStateException("could not disassemble " + start);
        }
        Function f = getFunctionContaining(a);
        if (f == null) f = getFunctionAt(start);
        if (f == null) f = createFunction(start, null);
        if (f != null) CreateFunctionCmd.fixupFunctionBody(currentProgram, f, monitor);
        return f;
    }

    // FClassFunctionLinkInfo tables are {construct getter, name} pairs, so the pointer after a name there is the
    // getter of the NEXT entry. A getter references its FFunctionParams, whose NameUTF8 (+0x10) is that entry's name.
    boolean isNextConstructGetter(Address fn, Address nameRef) throws Exception {
        Memory mem = currentProgram.getMemory();
        long nextName;
        try {
            nextName = mem.getLong(nameRef.add(16));
        } catch (Exception e) {
            return false;
        }
        Function f = ensure(fn);
        if (f == null) return false;
        // Without auto-analysis there are no operand references: read the operands themselves. A memory operand is an
        // Address; a rip-relative LEA's target comes back as a Scalar.
        for (Instruction ins : currentProgram.getListing().getInstructions(f.getBody(), true)) {
            for (int i = 0; i < ins.getNumOperands(); i++) {
                for (Object o : ins.getOpObjects(i)) {
                    Address d = o instanceof Address ? (Address) o
                        : o instanceof Scalar ? toAddr(((Scalar) o).getUnsignedValue()) : null;
                    if (d == null || !mem.contains(d)) continue;
                    try {
                        if (mem.getLong(d.add(0x10)) == nextName) return true;
                    } catch (Exception e) {
                        // not readable data
                    }
                }
            }
        }
        return false;
    }

    void emit(String label, Address a, int depth) {
        if (done.contains(a) || done.size() >= MAX_FUNCTIONS) return;
        done.add(a);
        List<Address> calls = new ArrayList<>();
        String file = "", msg = "", status = "failed";
        try {
            Function f = ensure(a);
            if (f == null) throw new IllegalStateException("could not create a function at " + a);
            for (Instruction ins : currentProgram.getListing().getInstructions(f.getBody(), true)) {
                if (!ins.getFlowType().isCall()) continue;
                for (Address t : ins.getFlows()) if (!calls.contains(t)) calls.add(t);
            }
            DecompileResults r = dec.decompileFunction(f, 120, monitor);
            if (!r.decompileCompleted() || r.getDecompiledFunction() == null) {
                throw new IllegalStateException("decompiler: " + r.getErrorMessage());
            }
            file = label.replaceAll("[^A-Za-z0-9_]", "_") + "_" + f.getEntryPoint() + ".c";
            StringBuilder c = new StringBuilder("// " + label + " at " + f.getEntryPoint()
                + " (Ghidra pseudocode of the machine code, not the original source)\n// direct calls:");
            for (Address t : calls) c.append(' ').append(t);
            c.append('\n').append(r.getDecompiledFunction().getC());
            Files.writeString(out.resolve(file), c.toString(), StandardCharsets.UTF_8);
            status = "ok";
            ok++;
        } catch (Exception e) {
            msg = e.toString();
            failed++;
        }
        record(label, a.toString(), status, file, msg);
        if (depth > 0) for (Address t : calls) emit(label + "_callee", t, depth - 1);
    }

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 3) throw new IllegalArgumentException("args: <out dir> <depth> <target>...");
        out = Path.of(args[0]);
        int depth = Integer.parseInt(args[1]);
        dec = new DecompInterface();
        dec.toggleCCode(true);
        try {
            if (!dec.openProgram(currentProgram)) throw new IllegalStateException(dec.getLastMessage());
            for (int i = 2; i < args.length; i++) {
                String t = args[i];
                if (t.startsWith("0x")) {
                    emit("va", toAddr(Long.parseUnsignedLong(t.substring(2), 16)), depth);
                    continue;
                }
                List<Address> thunks = thunksFor(t);
                if (thunks.isEmpty()) {
                    record(t, t, "failed", "", "no FNameNativePtrPair entry for this name");
                    failed++;
                }
                for (Address a : thunks) emit(t, a, depth);
            }
        } finally {
            dec.dispose();
        }
        // Written last: a missing targets.json means the run did not finish.
        Files.writeString(out.resolve("targets.json"), "{\"ok\":" + ok + ",\"failed\":" + failed
            + ",\"functions\":[\n" + String.join(",\n", rows) + "\n]}\n", StandardCharsets.UTF_8);
    }
}
