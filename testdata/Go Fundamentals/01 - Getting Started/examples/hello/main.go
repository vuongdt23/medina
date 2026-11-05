package main

import (
	"fmt"
	"os"
)

func main() {
	name := "Gopher"
	if len(os.Args) > 1 {
		name = os.Args[1]
	}
	fmt.Println(greet(name))
}
