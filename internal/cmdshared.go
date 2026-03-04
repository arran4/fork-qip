package qinternal

import "strings"

// NormalizeFlagArgs lets users place flags before or after positional args.
// It preserves "--" so standard flag terminator semantics remain intact.
func NormalizeFlagArgs(args []string, flagsWithValue map[string]struct{}) []string {
	if len(args) == 0 {
		return args
	}

	normalized := make([]string, 0, len(args))
	positionals := make([]string, 0, len(args))
	sawTerminator := false

	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			sawTerminator = true
			positionals = append(positionals, args[i+1:]...)
			break
		}
		if strings.HasPrefix(arg, "-") && arg != "-" {
			normalized = append(normalized, arg)
			if strings.Contains(arg, "=") {
				continue
			}
			if _, ok := flagsWithValue[arg]; ok && i+1 < len(args) {
				i++
				normalized = append(normalized, args[i])
			}
			continue
		}
		positionals = append(positionals, arg)
	}

	if sawTerminator {
		normalized = append(normalized, "--")
	}
	normalized = append(normalized, positionals...)
	return normalized
}
