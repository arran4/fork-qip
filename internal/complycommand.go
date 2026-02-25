package qinternal

import (
	"context"
	"crypto/sha256"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

const usageComply = "Usage: qip comply <impl.wasm> [--with <compliance.wasm> ...] [-v|--verbose] [--timeout-ms <ms>]"

const (
	implModuleName                = "impl"
	complyExportMemory            = "memory"
	complyExportRun               = "run"
	complyExportInputPtr          = "input_ptr"
	complyExportInputUTF8Cap      = "input_utf8_cap"
	complyExportInputBytesCap     = "input_bytes_cap"
	complyExportTileRGBA64        = "tile_rgba_f32_64x64"
	complyExportComply            = "comply"
	defaultComplianceTimeout      = 5 * time.Second
	maxFailurePreviewBytes        = 256
	minComplianceTimeoutMS    int = 1
)

type stringListFlag []string

func (s *stringListFlag) String() string {
	return strings.Join(*s, ",")
}

func (s *stringListFlag) Set(v string) error {
	if strings.TrimSpace(v) == "" {
		return errors.New("--with path must not be empty")
	}
	*s = append(*s, v)
	return nil
}

type moduleKind string

const (
	moduleKindRun        moduleKind = "run"
	moduleKindTile       moduleKind = "tile"
	moduleKindRunAndTile moduleKind = "run+tile"
)

type baseValidationResult struct {
	kind moduleKind
}

type complianceSpec struct {
	index int
	path  string
	wasm  []byte
}

type complianceOutcomes struct {
	index    int
	path     string
	passed   bool
	err      error
	detail   string
	duration time.Duration
}

func RunComplyCommand(args []string) error {
	fs := flag.NewFlagSet("comply", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var withCompliances stringListFlag
	var verbose bool
	var timeoutMS int
	fs.Var(&withCompliances, "with", "compliance module (repeatable)")
	fs.BoolVar(&verbose, "v", false, "enable verbose logging")
	fs.BoolVar(&verbose, "verbose", false, "enable verbose logging")
	fs.IntVar(&timeoutMS, "timeout-ms", int(defaultComplianceTimeout/time.Millisecond), "per-compliance execution timeout in milliseconds")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%s %w", usageComply, err)
	}

	rest := fs.Args()
	if len(rest) != 1 {
		return errors.New(usageComply)
	}
	if timeoutMS < minComplianceTimeoutMS {
		return fmt.Errorf("%s invalid timeout-ms: %d", usageComply, timeoutMS)
	}
	complianceTimeout := time.Duration(timeoutMS) * time.Millisecond

	implPath := rest[0]
	implWasm, err := readComplyModulePath(implPath)
	if err != nil {
		return err
	}

	if verbose {
		sum := sha256.Sum256(implWasm)
		fmt.Fprintf(os.Stderr, "impl sha256: %x\n", sum)
	}

	base, err := validateBaseContract(implWasm)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "comply: base contract valid (%s module)\n", base.kind)

	if len(withCompliances) == 0 {
		return nil
	}

	compliances := make([]complianceSpec, 0, len(withCompliances))
	for i, path := range withCompliances {
		body, err := readComplyModulePath(path)
		if err != nil {
			return fmt.Errorf("failed to read --with %q: %w", path, err)
		}
		if verbose {
			sum := sha256.Sum256(body)
			fmt.Fprintf(os.Stderr, "compliance[%d] %s sha256: %x\n", i+1, path, sum)
		}
		compliances = append(compliances, complianceSpec{index: i, path: path, wasm: body})
	}

	outcomes := make(chan complianceOutcomes, len(compliances))
	var wg sync.WaitGroup
	for _, compliance := range compliances {
		wg.Go(func() {
			outcomes <- runComplianceModule(implWasm, compliance, complianceTimeout)
		})
	}
	wg.Wait()
	close(outcomes)

	results := make([]complianceOutcomes, 0, len(compliances))
	for out := range outcomes {
		results = append(results, out)
	}
	sort.Slice(results, func(i, j int) bool { return results[i].index < results[j].index })

	failCount := 0
	for _, out := range results {
		if out.passed {
			fmt.Fprintf(os.Stderr, "comply: PASS --with %s (%dms)\n", out.path, out.duration.Milliseconds())
			continue
		}
		failCount++
		fmt.Fprintf(os.Stderr, "comply: FAIL --with %s (%dms): %v\n", out.path, out.duration.Milliseconds(), out.err)
		if out.detail != "" {
			fmt.Fprintf(os.Stderr, "%s\n", out.detail)
		}
	}

	if failCount > 0 {
		return fmt.Errorf("compliance failed: %d/%d compliance modules failed", failCount, len(results))
	}
	return nil
}

func readComplyModulePath(path string) ([]byte, error) {
	if strings.HasPrefix(path, "https://") {
		resp, err := http.Get(path)
		if err != nil {
			return nil, fmt.Errorf("Error fetching URL: %v", err)
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, fmt.Errorf("Error reading response: %v", err)
		}
		return body, nil
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("Error reading file: %v", err)
	}
	return body, nil
}

func validateBaseContract(implWasm []byte) (baseValidationResult, error) {
	ctx := context.Background()
	r := wasmruntime.New(ctx)
	defer r.Close(ctx)

	compiled, err := r.CompileModule(ctx, implWasm)
	if err != nil {
		return baseValidationResult{}, errors.New("Wasm module could not be compiled")
	}
	defer compiled.Close(ctx)

	mod, err := r.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName(implModuleName))
	if err != nil {
		return baseValidationResult{}, errors.New("Wasm module could not be instantiated")
	}
	defer mod.Close(ctx)

	if mod.ExportedMemory(complyExportMemory) == nil {
		return baseValidationResult{}, errors.New("Wasm module must export memory")
	}

	funcs := compiled.ExportedFunctions()
	hasRun := false
	if runDef, ok := funcs[complyExportRun]; ok {
		if err := requireSignature(runDef, []api.ValueType{api.ValueTypeI32}, []api.ValueType{api.ValueTypeI32}, complyExportRun); err != nil {
			return baseValidationResult{}, err
		}
		if _, ok, err := getExportedI32(ctx, mod, complyExportInputPtr); err != nil {
			return baseValidationResult{}, err
		} else if !ok {
			return baseValidationResult{}, errors.New("Wasm run module must export input_ptr as global or function")
		}
		if _, ok, err := getExportedI32(ctx, mod, complyExportInputUTF8Cap); err != nil {
			return baseValidationResult{}, err
		} else if ok {
			hasRun = true
		} else if _, ok, err := getExportedI32(ctx, mod, complyExportInputBytesCap); err != nil {
			return baseValidationResult{}, err
		} else if ok {
			hasRun = true
		} else {
			return baseValidationResult{}, errors.New("Wasm run module must export input_utf8_cap or input_bytes_cap as global or function")
		}
	}

	hasTile := false
	if tileDef, ok := funcs[complyExportTileRGBA64]; ok {
		if err := requireSignature(tileDef, []api.ValueType{api.ValueTypeF32, api.ValueTypeF32}, []api.ValueType{}, complyExportTileRGBA64); err != nil {
			return baseValidationResult{}, err
		}
		if _, ok, err := getExportedI32(ctx, mod, complyExportInputPtr); err != nil {
			return baseValidationResult{}, err
		} else if !ok {
			return baseValidationResult{}, errors.New("Wasm tile module must export input_ptr as global or function")
		}
		if _, ok, err := getExportedI32(ctx, mod, complyExportInputBytesCap); err != nil {
			return baseValidationResult{}, err
		} else if !ok {
			return baseValidationResult{}, errors.New("Wasm tile module must export input_bytes_cap as global or function")
		}
		hasTile = true
	}

	switch {
	case hasRun && hasTile:
		return baseValidationResult{kind: moduleKindRunAndTile}, nil
	case hasRun:
		return baseValidationResult{kind: moduleKindRun}, nil
	case hasTile:
		return baseValidationResult{kind: moduleKindTile}, nil
	default:
		return baseValidationResult{}, errors.New("Wasm module is neither a run module nor a tile module")
	}
}

func requireSignature(def api.FunctionDefinition, wantParams []api.ValueType, wantResults []api.ValueType, name string) error {
	if !sameTypes(def.ParamTypes(), wantParams) || !sameTypes(def.ResultTypes(), wantResults) {
		return fmt.Errorf("Wasm module export %s has invalid signature", name)
	}
	return nil
}

func sameTypes(a []api.ValueType, b []api.ValueType) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func getExportedI32(ctx context.Context, mod api.Module, name string) (int32, bool, error) {
	if g := mod.ExportedGlobal(name); g != nil {
		return int32(uint32(g.Get())), true, nil
	}
	if fn := mod.ExportedFunction(name); fn != nil {
		res, err := fn.Call(ctx)
		if err != nil {
			return 0, true, wasmruntime.HumanizeExecutionError(ctx, err)
		}
		if len(res) != 1 {
			return 0, true, fmt.Errorf("%s() returned %d values, want 1", name, len(res))
		}
		return api.DecodeI32(res[0]), true, nil
	}
	return 0, false, nil
}

func runComplianceModule(implWasm []byte, compliance complianceSpec, timeout time.Duration) complianceOutcomes {
	out := complianceOutcomes{
		index: compliance.index,
		path:  compliance.path,
	}
	start := time.Now()
	defer func() { out.duration = time.Since(start) }()

	ctx := context.Background()
	r := wasmruntime.New(ctx)
	defer r.Close(ctx)

	implCompiled, err := r.CompileModule(ctx, implWasm)
	if err != nil {
		out.err = errors.New("implementation module could not be compiled")
		return out
	}
	defer implCompiled.Close(ctx)

	complianceCompiled, err := r.CompileModule(ctx, compliance.wasm)
	if err != nil {
		out.err = errors.New("compliance module could not be compiled")
		return out
	}
	defer complianceCompiled.Close(ctx)

	if err := ensurecomplianceImportsImplMemory(complianceCompiled); err != nil {
		out.err = err
		return out
	}

	if err := ensurecomplianceComplySignature(complianceCompiled); err != nil {
		out.err = err
		return out
	}

	implMod, err := r.InstantiateModule(ctx, implCompiled, wazero.NewModuleConfig().WithName(implModuleName))
	if err != nil {
		out.err = errors.New("implementation module could not be instantiated")
		return out
	}
	defer implMod.Close(ctx)

	complianceMod, err := r.InstantiateModule(ctx, complianceCompiled, wazero.NewModuleConfig().WithName("compliance-compliance"))
	if err != nil {
		out.err = fmt.Errorf("compliance module could not be instantiated (imports must bind to %q): %w", implModuleName, err)
		return out
	}
	defer complianceMod.Close(ctx)

	complyFn := complianceMod.ExportedFunction(complyExportComply)
	if complyFn == nil {
		out.err = errors.New(`compliance module must export comply() -> i32`)
		return out
	}

	complianceCtx := context.Background()
	complianceCtx, cancel := wasmruntime.WithExecutionTimeout(complianceCtx, timeout)
	defer cancel()

	res, err := complyFn.Call(complianceCtx)
	if err != nil {
		out.err = wasmruntime.HumanizeExecutionError(complianceCtx, err)
		out.detail = collectFailureDetail(complianceCtx, implMod, complianceMod)
		return out
	}
	if len(res) != 1 {
		out.err = fmt.Errorf("comply() returned %d values, want 1", len(res))
		out.detail = collectFailureDetail(complianceCtx, implMod, complianceMod)
		return out
	}

	status := api.DecodeI32(res[0])
	if status > 0 {
		out.passed = true
		return out
	}

	out.err = fmt.Errorf("comply() reported failure status=%d", status)
	out.detail = collectFailureDetail(complianceCtx, implMod, complianceMod)
	return out
}

func ensurecomplianceImportsImplMemory(compiled wazero.CompiledModule) error {
	memImports := compiled.ImportedMemories()
	for _, mem := range memImports {
		mod, name, ok := mem.Import()
		if ok && mod == implModuleName && name == complyExportMemory {
			return nil
		}
	}
	return fmt.Errorf("compliance module must import %s.%s", implModuleName, complyExportMemory)
}

func ensurecomplianceComplySignature(compiled wazero.CompiledModule) error {
	def, ok := compiled.ExportedFunctions()[complyExportComply]
	if !ok {
		return errors.New(`compliance module must export comply() -> i32`)
	}
	if err := requireSignature(def, []api.ValueType{}, []api.ValueType{api.ValueTypeI32}, complyExportComply); err != nil {
		return errors.New(`compliance module export comply must have signature () -> i32`)
	}
	return nil
}

func collectFailureDetail(ctx context.Context, implMod api.Module, complianceMod api.Module) string {
	mem := implMod.Memory()
	if mem == nil {
		mem = complianceMod.Memory()
	}
	if mem == nil {
		return ""
	}

	var parts []string
	if msg := readFailureString(ctx, complianceMod, mem, []string{"failure_message", "fail_message"}); msg != "" {
		parts = append(parts, "message: "+msg)
	}
	if in := readFailureBytes(ctx, complianceMod, mem, []string{"failure_input", "fail_input"}); len(in) > 0 {
		parts = append(parts, "input_utf8_preview="+previewUTF8(in))
		parts = append(parts, "input_hex_preview="+previewHex(in))
	}
	if out := readFailureBytes(ctx, complianceMod, mem, []string{"failure_output", "fail_output"}); len(out) > 0 {
		parts = append(parts, "output_utf8_preview="+previewUTF8(out))
		parts = append(parts, "output_hex_preview="+previewHex(out))
	}
	if len(parts) == 0 {
		return "no failure detail exports found; optional exports: failure_message_ptr/size, failure_input_ptr/size, failure_output_ptr/size"
	}
	return strings.Join(parts, "\n")
}

func readFailureString(ctx context.Context, mod api.Module, mem api.Memory, bases []string) string {
	data := readFailureBytes(ctx, mod, mem, bases)
	if len(data) == 0 {
		return ""
	}
	return string(data)
}

func readFailureBytes(ctx context.Context, mod api.Module, mem api.Memory, bases []string) []byte {
	for _, base := range bases {
		ptrName := base + "_ptr"
		sizeName := base + "_size"
		ptr, ok, err := getExportedI32(ctx, mod, ptrName)
		if err != nil || !ok {
			continue
		}
		size, ok, err := getExportedI32(ctx, mod, sizeName)
		if err != nil || !ok {
			continue
		}
		if ptr < 0 || size <= 0 {
			continue
		}
		raw, ok := mem.Read(uint32(ptr), uint32(size))
		if !ok {
			continue
		}
		clone := append([]byte(nil), raw...)
		return clone
	}
	return nil
}

func previewUTF8(in []byte) string {
	if len(in) > maxFailurePreviewBytes {
		in = in[:maxFailurePreviewBytes]
	}
	var b strings.Builder
	for _, c := range in {
		if c >= 0x20 && c <= 0x7e {
			b.WriteByte(c)
		} else {
			b.WriteString(fmt.Sprintf("\\x%02x", c))
		}
	}
	return b.String()
}

func previewHex(in []byte) string {
	if len(in) > maxFailurePreviewBytes {
		in = in[:maxFailurePreviewBytes]
	}
	var b strings.Builder
	for i, c := range in {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(fmt.Sprintf("%02x", c))
	}
	return b.String()
}
