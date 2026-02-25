package qinternal

import (
	"fmt"
	"io"
	"io/fs"
	"mime"
	"net/http"
	"net/http/httptest"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

type InProcessHTTPResponse struct {
	StatusCode int
	Header     http.Header
	Body       []byte
}

type ContentRoute struct {
	FilePath   string
	SourceMIME string
}

type RoutedResponse struct {
	StatusCode             int
	Header                 http.Header
	Body                   []byte
	ModuleDurations        []time.Duration
	InstantiationDurations []time.Duration
}

type RequestHandlerConfig struct {
	LogPrefix      string
	Reload         func()
	Resolve        func(r *http.Request, requestID uint64) (RoutedResponse, error)
	WriteError     func(http.ResponseWriter, error)
	FormatDuration func(total time.Duration, moduleDurations []time.Duration, instantiationDurations []time.Duration) string
	Logf           func(format string, args ...any)
}

func NewRequestHandler(config RequestHandlerConfig) http.Handler {
	logf := config.Logf
	if logf == nil {
		logf = func(string, ...any) {}
	}
	writeError := config.WriteError
	if writeError == nil {
		writeError = func(w http.ResponseWriter, err error) {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	}
	formatDuration := config.FormatDuration
	if formatDuration == nil {
		formatDuration = func(total time.Duration, moduleDurations []time.Duration, instantiationDurations []time.Duration) string {
			return fmt.Sprintf("duration_ms=%d", total.Milliseconds())
		}
	}

	mux := http.NewServeMux()
	var requestID uint64
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		reqID := atomic.AddUint64(&requestID, 1)
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			emptyDurations := []time.Duration{}
			emptyInst := []time.Duration{}
			w.WriteHeader(http.StatusMethodNotAllowed)
			logf("%s: %s %s %s", config.LogPrefix, r.Method, r.URL.Path, formatDuration(time.Since(start), emptyDurations, emptyInst))
			return
		}

		if config.Reload != nil {
			config.Reload()
		}

		response, err := config.Resolve(r, reqID)
		if err != nil {
			writeError(w, err)
			logf("%s: %s %s error=%v %s", config.LogPrefix, r.Method, r.URL.Path, err, formatDuration(time.Since(start), response.ModuleDurations, response.InstantiationDurations))
			return
		}

		for name, values := range response.Header {
			for _, value := range values {
				w.Header().Add(name, value)
			}
		}
		if len(response.Body) > 0 && w.Header().Get("Content-Length") == "" {
			w.Header().Set("Content-Length", strconv.Itoa(len(response.Body)))
		}
		if response.StatusCode == 0 {
			response.StatusCode = http.StatusOK
		}
		w.WriteHeader(response.StatusCode)
		if r.Method != http.MethodHead && len(response.Body) > 0 {
			if _, err := w.Write(response.Body); err != nil {
				logf("%s: %s %s write_error=%v %s", config.LogPrefix, r.Method, r.URL.Path, err, formatDuration(time.Since(start), response.ModuleDurations, response.InstantiationDurations))
				return
			}
		}

		logf("%s: %s %s status=%d %s", config.LogPrefix, r.Method, r.URL.Path, response.StatusCode, formatDuration(time.Since(start), response.ModuleDurations, response.InstantiationDurations))
	})

	return mux
}

func ServeInProcessHTTP(handler http.Handler, method string, requestPath string, headers http.Header) (InProcessHTTPResponse, error) {
	if handler == nil {
		return InProcessHTTPResponse{}, fmt.Errorf("handler is nil")
	}
	if method == "" {
		method = http.MethodGet
	}
	if requestPath == "" {
		requestPath = "/"
	}
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}

	req := httptest.NewRequest(method, "http://qip.local"+requestPath, nil)
	for key, values := range headers {
		for _, value := range values {
			req.Header.Add(key, value)
		}
	}

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	resp := recorder.Result()
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return InProcessHTTPResponse{}, fmt.Errorf("failed to read in-process response body: %w", err)
	}
	if method == http.MethodHead {
		if resp.Header.Get("Content-Length") == "" && len(body) > 0 {
			resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
		}
		body = nil
	}

	return InProcessHTTPResponse{
		StatusCode: resp.StatusCode,
		Header:     resp.Header.Clone(),
		Body:       body,
	}, nil
}

func BuildContentRoutes(contentRoot string) (map[string]ContentRoute, error) {
	files := make([]struct {
		rel  string
		full string
	}, 0, 32)
	err := filepath.WalkDir(contentRoot, func(fullPath string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		if !d.Type().IsRegular() {
			return fmt.Errorf("content entry %q must be a regular file", fullPath)
		}
		relPath, err := filepath.Rel(contentRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		if !utf8.ValidString(relPath) {
			return fmt.Errorf("content path %q must be valid UTF-8", relPath)
		}
		if strings.Contains(relPath, "\\") {
			return fmt.Errorf("content path %q must not contain backslash", relPath)
		}
		if strings.HasPrefix(relPath, "/") {
			return fmt.Errorf("content path %q must not start with /", relPath)
		}
		cleanRel := path.Clean(relPath)
		if cleanRel != relPath || cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, "../") {
			return fmt.Errorf("content path %q is not canonical", relPath)
		}
		files = append(files, struct {
			rel  string
			full string
		}{rel: relPath, full: fullPath})
		return nil
	})
	if err != nil {
		return nil, err
	}

	sort.Slice(files, func(i, j int) bool {
		return files[i].rel < files[j].rel
	})

	routes := make(map[string]ContentRoute, len(files))
	for _, entry := range files {
		aliases := contentRequestPaths(entry.rel)
		route := ContentRoute{
			FilePath:   entry.full,
			SourceMIME: detectSourceMIME(entry.rel),
		}
		for _, requestPath := range aliases {
			if prev, exists := routes[requestPath]; exists && prev.FilePath != route.FilePath {
				return nil, fmt.Errorf("duplicate route path %q for %q and %q", requestPath, prev.FilePath, route.FilePath)
			}
			routes[requestPath] = route
		}
	}

	return routes, nil
}

func ResolveContentRoute(routes map[string]ContentRoute, requestPath string) (ContentRoute, bool) {
	if requestPath == "" {
		requestPath = "/"
	}
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}

	candidates := []string{requestPath}
	clean := path.Clean(requestPath)
	if clean == "." {
		clean = "/"
	}
	if !strings.HasPrefix(clean, "/") {
		clean = "/" + clean
	}
	if clean != requestPath {
		candidates = append(candidates, clean)
	}
	if requestPath != "/" {
		if before, ok := strings.CutSuffix(requestPath, "/"); ok {
			candidates = append(candidates, before)
		} else {
			candidates = append(candidates, requestPath+"/")
		}
	}

	seen := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		if _, ok := seen[candidate]; ok {
			continue
		}
		seen[candidate] = struct{}{}
		if route, ok := routes[candidate]; ok {
			return route, true
		}
	}
	return ContentRoute{}, false
}

func contentRequestPaths(relPath string) []string {
	out := make([]string, 0, 4)
	appendUnique := func(value string) {
		if slices.Contains(out, value) {
			return
		}
		out = append(out, value)
	}

	appendUnique("/" + relPath)
	ext := path.Ext(relPath)
	lowerExt := strings.ToLower(ext)
	if lowerExt == ".html" || lowerExt == ".md" || lowerExt == ".markdown" {
		base := path.Base(relPath)
		if strings.EqualFold(base, "index"+ext) {
			dir := path.Dir(relPath)
			if dir == "." {
				appendUnique("/")
			} else {
				appendUnique("/" + dir)
				appendUnique("/" + dir + "/")
			}
		} else {
			appendUnique("/" + strings.TrimSuffix(relPath, ext))
		}
	}
	return out
}

func detectSourceMIME(relPath string) string {
	ext := strings.ToLower(path.Ext(relPath))
	switch ext {
	case ".md", ".markdown":
		return "text/markdown"
	}

	mimeType := mime.TypeByExtension(ext)
	if mimeType == "" {
		return "application/octet-stream"
	}
	if cut := strings.IndexByte(mimeType, ';'); cut != -1 {
		mimeType = strings.TrimSpace(mimeType[:cut])
	}
	if mimeType == "" {
		return "application/octet-stream"
	}
	return mimeType
}
