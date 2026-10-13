package main

import "unsafe"

func unsafePointer(p *uint32) unsafe.Pointer { return unsafe.Pointer(p) }
