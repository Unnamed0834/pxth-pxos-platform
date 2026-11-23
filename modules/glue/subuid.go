package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

var lchownFn = os.Lchown

func cmdSubuidWalk(args []string) error {
	if err := needArgs("subuid-walk", args, 4); err != nil {
		return err
	}
	old, err := strconv.Atoi(args[1])
	if err != nil {
		return fmt.Errorf("subuid-walk: old base: %w", err)
	}
	newBase, err := strconv.Atoi(args[2])
	if err != nil {
		return fmt.Errorf("subuid-walk: new base: %w", err)
	}
	count, err := strconv.Atoi(args[3])
	if err != nil {
		return fmt.Errorf("subuid-walk: count: %w", err)
	}
	return subuidWalk(args[0], old, count, newBase-old)
}

func subuidWalk(root string, old, count, delta int) error {
	if _, err := shiftPath(root, old, count, delta); err != nil {
		return err
	}
	return walkShift(root, old, count, delta)
}

func walkShift(dir string, old, count, delta int) error {
	entries, err := os.ReadDir(dir)
	if err != nil {

		return nil
	}
	for _, entry := range entries {
		path := filepath.Join(dir, entry.Name())
		fi, err := shiftPath(path, old, count, delta)
		if err != nil {
			return err
		}
		if fi.IsDir() {
			if err := walkShift(path, old, count, delta); err != nil {
				return err
			}
		}
	}
	return nil
}

func shiftPath(path string, old, count, delta int) (os.FileInfo, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return nil, fmt.Errorf("subuid-walk: no owner for %s", path)
	}
	uid := int(st.Uid)
	gid := int(st.Gid)
	nuid, ngid := uid, gid
	if uid >= old && uid < old+count {
		nuid = uid + delta
	}
	if gid >= old && gid < old+count {
		ngid = gid + delta
	}
	if nuid != uid || ngid != gid {
		if err := lchownFn(path, nuid, ngid); err != nil {
			return nil, err
		}
	}
	return fi, nil
}
