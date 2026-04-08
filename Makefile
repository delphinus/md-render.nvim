NVIM := nvim --headless -u NONE --noplugin

TEST_FILES := $(sort $(wildcard tests/*_test.lua))

.PHONY: test $(TEST_FILES)

test: $(TEST_FILES)

$(TEST_FILES):
	$(NVIM) -l $@
