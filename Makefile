.PHONY: build test app run install clean

build:
	swift build

test:
	swift test

app:
	scripts/bundle.sh release

run: app
	open build/MailMind.app

install: app
	rm -rf /Applications/MailMind.app
	cp -R build/MailMind.app /Applications/
	@echo "已安装到 /Applications/MailMind.app"

clean:
	rm -rf .build build
