package qinternal

import (
	"strings"
	"testing"
)

func TestBuildViewSourceIndexHTMLIncludesModules(t *testing.T) {
	html := string(BuildViewSourceIndexHTML(
		[]RecipeSourceAsset{
			{RequestPath: "/view-source/recipes/text/markdown/10-markdown-basic.zig"},
		},
		[]string{"/guide.md"},
		[]string{
			"/modules/utf8/trim.wasm",
			"/modules/utf8/trim.wasm",
			"/not-modules/ignored.wasm",
		},
		[]RecipeSourceAsset{
			{RequestPath: "/view-source/modules/utf8/trim.zig"},
			{RequestPath: "/view-source/modules/utf8/styles.css"},
			{RequestPath: "/view-source/modules/utf8/trim.wasm"},
			{RequestPath: "/view-source/recipes/ignored.zig"},
		},
	))

	if !strings.Contains(html, "<h2>Modules</h2>") {
		t.Fatalf("missing modules heading: %q", html)
	}
	contentPos := strings.Index(html, "<h2>Content</h2>")
	recipesPos := strings.Index(html, "<h2>Recipes</h2>")
	if contentPos < 0 || recipesPos < 0 || contentPos > recipesPos {
		t.Fatalf("expected Content section before Recipes section: %q", html)
	}
	if got := strings.Count(html, "<h2>Modules</h2>"); got != 1 {
		t.Fatalf("modules heading count=%d, want 1", got)
	}
	if !strings.Contains(html, "href=\"/modules/utf8/trim.wasm\"") {
		t.Fatalf("missing module href: %q", html)
	}
	if strings.Contains(html, "href=\"/not-modules/ignored.wasm\"") {
		t.Fatalf("unexpected non-module href: %q", html)
	}
	if got := strings.Count(html, "href=\"/modules/utf8/trim.wasm\""); got != 1 {
		t.Fatalf("module href count=%d, want 1", got)
	}
	if strings.Contains(html, "<h2>Module Sources</h2>") {
		t.Fatalf("unexpected module sources heading: %q", html)
	}
	if !strings.Contains(html, "href=\"/view-source/modules/utf8/trim.zig\"") {
		t.Fatalf("missing module source href: %q", html)
	}
	if !strings.Contains(html, "href=\"/view-source/modules/utf8/styles.css\"") {
		t.Fatalf("missing module source css href: %q", html)
	}
	if strings.Contains(html, "href=\"/view-source/modules/utf8/trim.wasm\"") {
		t.Fatalf("expected runtime wasm href to be preferred over view-source wasm href: %q", html)
	}
	if strings.Contains(html, "href=\"/view-source/recipes/ignored.zig\"") {
		t.Fatalf("unexpected non-module source href: %q", html)
	}
}
