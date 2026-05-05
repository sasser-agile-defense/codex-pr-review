"""A deliberately small file used by tests/test-verifier.sh.

The hallucinated finding fixture cites line 42, but this file has fewer
than 42 lines, so a grounded verifier must return `refuted`.
"""


def add(a, b):
    return a + b


def multiply(a, b):
    return a * b


if __name__ == "__main__":
    print(add(2, 3))
    print(multiply(2, 3))
