package main

import "testing"

func TestGreet(t *testing.T) {
	for _, test := range []struct {
		name string
		want string
	}{
		{name: "Ada", want: "Hello, Ada!"},
		{name: "  ", want: "Hello, there!"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := greet(test.name); got != test.want {
				t.Fatalf("greet(%q) = %q, want %q", test.name, got, test.want)
			}
		})
	}
}
