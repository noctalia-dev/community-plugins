class NodePropertyError(Exception):
    pass


class NodeIDAbsentError(NodePropertyError):
    pass


class NodePropertyAbsentError(NodePropertyError):
    pass


class MultipleRootError(Exception):
    pass


class DuplicatedNodeIdError(Exception):
    pass


class LinkPastRootNodeError(Exception):
    pass


class InvalidLevelNumber(Exception):
    pass


class LoopError(Exception):
    pass


