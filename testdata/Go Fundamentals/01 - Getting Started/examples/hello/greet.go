package main

import "strings"

// greet returns a friendly greeting for name. Empty names get a useful default.
func greet(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "there"
	}
	return "Hello, " + name + "!"
}
