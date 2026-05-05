"""Fixture file for the real-bug-finding verifier test.

Line 11 dereferences `user` (the result of get_user) without checking
whether it is None — get_user can return None when the lookup misses.
"""


def get_user(user_id):
    return None  # simulate a cache miss


def fetch_email(user_id):
    user = get_user(user_id)
    return user.email  # line 13: NoneType has no attribute 'email'


if __name__ == "__main__":
    print(fetch_email(1))
