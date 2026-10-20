.PHONY: test

test:
	kyverno test tests --detailed-results --require-tests
