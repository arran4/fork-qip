package qinternal

import (
	"fmt"
	"html"
	"io/fs"
	"mime"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

type RecipeSourceAsset struct {
	RequestPath string
	Body        []byte
	ContentType string
}

func CollectRecipeSourceAssets(recipesRoot string) ([]RecipeSourceAsset, error) {
	assets := make([]RecipeSourceAsset, 0, 32)
	err := filepath.WalkDir(recipesRoot, func(fullPath string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}

		relPath, err := filepath.Rel(recipesRoot, fullPath)
		if err != nil {
			return err
		}
		relPath = filepath.ToSlash(relPath)
		if hasHiddenPathSegment(relPath) {
			return nil
		}
		body, err := os.ReadFile(fullPath)
		if err != nil {
			return err
		}
		assets = append(assets, RecipeSourceAsset{
			RequestPath: "/view-source/recipes/" + relPath,
			Body:        body,
			ContentType: detectRecipeSourceContentType(relPath, body),
		})
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("failed to enumerate recipe source files: %w", err)
	}
	sort.Slice(assets, func(i, j int) bool {
		return assets[i].RequestPath < assets[j].RequestPath
	})
	return assets, nil
}

func BuildViewSourceIndexHTML(recipeAssets []RecipeSourceAsset, markdownRequestPaths []string) []byte {
	markdownRequestPaths = FilterMarkdownRequestPaths(markdownRequestPaths)

	var b strings.Builder
	b.Grow(768 + len(recipeAssets)*96 + len(markdownRequestPaths)*64)
	b.WriteString("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>/view-source</title></head><body><h1>/view-source</h1>")
	b.WriteString("<h2>Recipes</h2><ul>")
	for _, asset := range recipeAssets {
		href := requestPathForHref(asset.RequestPath)
		label := strings.TrimPrefix(asset.RequestPath, "/view-source/recipes/")
		b.WriteString("<li><a href=\"")
		b.WriteString(html.EscapeString(href))
		b.WriteString("\">")
		b.WriteString(html.EscapeString(label))
		b.WriteString("</a></li>")
	}
	b.WriteString("</ul>")
	b.WriteString("<h2>Content</h2><ul>")
	for _, requestPath := range markdownRequestPaths {
		href := requestPathForHref(requestPath)
		label := requestPath
		b.WriteString("<li><a href=\"")
		b.WriteString(html.EscapeString(href))
		b.WriteString("\">")
		b.WriteString(html.EscapeString(label))
		b.WriteString("</a></li>")
	}
	b.WriteString("</ul></body></html>\n")
	return []byte(b.String())
}

func CollectMarkdownRequestPathsFromRoutes(routes map[string]ContentRoute) []string {
	paths := make([]string, 0, len(routes))
	for requestPath, route := range routes {
		if route.SourceMIME != "text/markdown" {
			continue
		}
		if !isMarkdownRequestPath(requestPath) {
			continue
		}
		paths = append(paths, requestPath)
	}
	return FilterMarkdownRequestPaths(paths)
}

func FilterMarkdownRequestPaths(paths []string) []string {
	out := make([]string, 0, len(paths))
	seen := make(map[string]struct{}, len(paths))
	for _, requestPath := range paths {
		if !isMarkdownRequestPath(requestPath) {
			continue
		}
		normalized := requestPath
		if !strings.HasPrefix(normalized, "/") {
			normalized = "/" + normalized
		}
		if _, ok := seen[normalized]; ok {
			continue
		}
		seen[normalized] = struct{}{}
		out = append(out, normalized)
	}
	sort.Strings(out)
	return out
}

func detectRecipeSourceContentType(relPath string, body []byte) string {
	ext := strings.ToLower(filepath.Ext(relPath))
	// TODO: this should be in a single, central location
	switch ext {
	case ".wasm":
		return "application/wasm"
	case ".zig":
		return "text/plain; charset=utf-8"
	case ".c", ".h":
		return "text/x-c; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js", ".mjs":
		return "text/javascript; charset=utf-8"
	case ".json":
		return "application/json"
	case ".md", ".markdown":
		return "text/markdown; charset=utf-8"
	case ".html", ".htm":
		return "text/html; charset=utf-8"
	}

	if byExt := mime.TypeByExtension(ext); byExt != "" {
		return byExt
	}
	if utf8.Valid(body) {
		return "text/plain; charset=utf-8"
	}
	return "application/octet-stream"
}

func hasHiddenPathSegment(relPath string) bool {
	for part := range strings.SplitSeq(relPath, "/") {
		if strings.HasPrefix(part, ".") {
			return true
		}
	}
	return false
}

func isMarkdownRequestPath(requestPath string) bool {
	ext := strings.ToLower(filepath.Ext(requestPath))
	return ext == ".md" || ext == ".markdown"
}

func requestPathForHref(requestPath string) string {
	if requestPath == "" {
		return "/"
	}
	if !strings.HasPrefix(requestPath, "/") {
		requestPath = "/" + requestPath
	}
	parts := strings.Split(strings.TrimPrefix(requestPath, "/"), "/")
	escaped := make([]string, 0, len(parts))
	for _, part := range parts {
		escaped = append(escaped, url.PathEscape(part))
	}
	return "/" + strings.Join(escaped, "/")
}
