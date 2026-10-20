.PHONY: test clean destroy

test:
	kyverno test tests --detailed-results --require-tests

clean:
	./scripts/clean.sh

destroy:
	./scripts/destroy.sh
