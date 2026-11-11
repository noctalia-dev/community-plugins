#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Copyright (C) 2011
# Brett Alistair Kromkamp - brettkromkamp@gmail.com
# Copyright (C) 2012-2017
# Xiaming Chen - chenxm35@gmail.com
# and other contributors.
# All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
from __future__ import print_function
from __future__ import unicode_literals

try:
    from builtins import str as text
except ImportError:
    from __builtin__ import str as text

import codecs
import json
import uuid
from copy import deepcopy
def python_2_unicode_compatible(cls):
	return cls

def iteritems(d):
	return iter(d.items())

try:
    from StringIO import StringIO
except ImportError:
    from io import StringIO

from .exceptions import *
from .node import Node

__author__ = 'chenxm'


@python_2_unicode_compatible
class Tree(object):

    (ROOT, DEPTH, WIDTH, ZIGZAG) = list(range(4))
    node_class = Node

    def __contains__(self, identifier):
        return identifier in self.nodes.keys()

    def __init__(self, tree=None, deep=False, node_class=None, identifier=None):
        self._identifier = None
        self._set_identifier(identifier)

        if node_class:
            assert issubclass(node_class, Node)
            self.node_class = node_class

        self._nodes = {}

        self.root = None

        if tree is not None:
            self.root = tree.root
            for nid, node in iteritems(tree.nodes):
                new_node = deepcopy(node) if deep else node
                self._nodes[nid] = new_node
                if tree.identifier != self._identifier:
                    new_node.clone_pointers(tree.identifier, self._identifier)

    def _clone(self, identifier=None, with_tree=False, deep=False):
        return self.__class__(identifier=identifier, tree=self if with_tree else None, deep=deep)

    @property
    def identifier(self):
        return self._identifier

    def _set_identifier(self, nid):
        if nid is None:
            self._identifier = str(uuid.uuid1())
        else:
            self._identifier = nid

    def __getitem__(self, key):
        try:
            return self._nodes[key]
        except KeyError:
            raise NodeIDAbsentError("Node '%s' is not in the tree" % key)

    def __len__(self):
        return len(self._nodes)

    def __str__(self):
        self._reader = ""

        def write(line):
            self._reader += line.decode('utf-8') + "\n"

        self.__print_backend(func=write)
        return self._reader

    def __print_backend(self, nid=None, level=ROOT, idhidden=True, filter=None,
                        key=None, reverse=False, line_type='ascii-ex',
                        data_property=None, func=print):
        if data_property:
            if idhidden:
                def get_label(node):
                    return getattr(node.data, data_property)
            else:
                def get_label(node):
                    return "%s[%s]" % (getattr(node.data, data_property), node.identifier)
        else:
            if idhidden:
                def get_label(node):
                    return node.tag
            else:
                def get_label(node):
                    return "%s[%s]" % (node.tag, node.identifier)

        if key is None:
            def key(node):
                return node

        for pre, node in self.__get(nid, level, filter, key, reverse,
                                    line_type):
            label = get_label(node)
            func('{0}{1}'.format(pre, label).encode('utf-8'))

    def __get(self, nid, level, filter_, key, reverse, line_type):
        if filter_ is None:
            def filter_(node):
                return True

        dt = {
            'ascii': ('|', '|-- ', '+-- '),
            'ascii-ex': ('\u2502', '\u251c\u2500\u2500 ', '\u2514\u2500\u2500 '),
            'ascii-exr': ('\u2502', '\u251c\u2500\u2500 ', '\u2570\u2500\u2500 '),
            'ascii-em': ('\u2551', '\u2560\u2550\u2550 ', '\u255a\u2550\u2550 '),
            'ascii-emv': ('\u2551', '\u255f\u2500\u2500 ', '\u2559\u2500\u2500 '),
            'ascii-emh': ('\u2502', '\u255e\u2550\u2550 ', '\u2558\u2550\u2550 '),
        }[line_type]

        return self.__get_iter(nid, level, filter_, key, reverse, dt, [])

    def __get_iter(self, nid, level, filter_, key, reverse, dt, is_last):
        dt_vertical_line, dt_line_box, dt_line_corner = dt

        nid = self.root if nid is None else nid
        node = self[nid]

        if level == self.ROOT:
            yield "", node
        else:
            leading = ''.join(map(lambda x: dt_vertical_line + ' ' * 3
            if not x else ' ' * 4, is_last[0:-1]))
            lasting = dt_line_corner if is_last[-1] else dt_line_box
            yield leading + lasting, node

        if filter_(node) and node.expanded:
            children = [self[i] for i in node.successors(self._identifier) if filter_(self[i])]
            idxlast = len(children) - 1
            if key:
                children.sort(key=key, reverse=reverse)
            elif reverse:
                children = reversed(children)
            level += 1
            for idx, child in enumerate(children):
                is_last.append(idx == idxlast)
                for item in self.__get_iter(child.identifier, level, filter_,
                                            key, reverse, dt, is_last):
                    yield item
                is_last.pop()

    def __update_bpointer(self, nid, parent_id):
        self[nid].set_predecessor(parent_id, self._identifier)

    def __update_fpointer(self, nid, child_id, mode):
        if nid is None:
            return
        else:
            self[nid].update_successors(child_id, mode, tree_id=self._identifier)

    def add_node(self, node, parent=None):
        if not isinstance(node, self.node_class):
            raise OSError(
                "First parameter must be object of {}".format(self.node_class))

        if node.identifier in self._nodes:
            raise DuplicatedNodeIdError("Can't create node "
                                        "with ID '%s'" % node.identifier)

        pid = parent.identifier if isinstance(
            parent, self.node_class) else parent

        if pid is None:
            if self.root is not None:
                raise MultipleRootError("A tree takes one root merely.")
            else:
                self.root = node.identifier
        elif not self.contains(pid):
            raise NodeIDAbsentError("Parent node '%s' "
                                    "is not in the tree" % pid)

        self._nodes.update({node.identifier: node})
        self.__update_fpointer(pid, node.identifier, self.node_class.ADD)
        self.__update_bpointer(node.identifier, pid)
        node.set_initial_tree_id(self._identifier)

    def all_nodes(self):
        return list(self._nodes.values())

    def all_nodes_itr(self):
        return self._nodes.values()

    def ancestor(self, nid, level=None):
        if not self.contains(nid):
            raise NodeIDAbsentError("Node '%s' is not in the tree" % nid)

        descendant = self[nid]
        ascendant = self[nid].bpointer
        ascendant_level = self.level(ascendant)

        if level is None:
            return ascendant
        elif nid == self.root:
            return self[nid]
        elif level >= self.level(descendant.identifier):
            raise InvalidLevelNumber("Descendant level (level %s) must be greater \
                                      than its ancestor's level (level %s)" % (str(self.level(descendant.identifier)), level))

        while ascendant is not None:
            if ascendant_level == level:
                return self[ascendant]
            else:
                descendant = ascendant
                ascendant = self[descendant].bpointer
                ascendant_level = self.level(ascendant)
        return None

    def children(self, nid):
        return [self[i] for i in self.is_branch(nid)]

    def contains(self, nid):
        return True if nid in self._nodes else False

    def create_node(self, tag=None, identifier=None, parent=None, data=None):
        node = self.node_class(tag=tag, identifier=identifier, data=data)
        self.add_node(node, parent)
        return node

    def depth(self, node=None):
        ret = 0
        if node is None:
            leaves = self.leaves()
            for leave in leaves:
                level = self.level(leave.identifier)
                ret = level if level >= ret else ret
        else:
            if not isinstance(node, self.node_class):
                nid = node
            else:
                nid = node.identifier
            if not self.contains(nid):
                raise NodeIDAbsentError("Node '%s' is not in the tree" % nid)
            ret = self.level(nid)
        return ret

    def expand_tree(self, nid=None, mode=DEPTH, filter=None, key=None,
                    reverse=False, sorting=True):
        nid = self.root if nid is None else nid
        if not self.contains(nid):
            raise NodeIDAbsentError("Node '%s' is not in the tree" % nid)

        filter = (lambda x: True) if (filter is None) else filter
        if filter(self[nid]):
            yield nid
            queue = [self[i] for i in self[nid].successors(self._identifier) if filter(self[i])]
            if mode in [self.DEPTH, self.WIDTH]:
                if sorting:
                    queue.sort(key=key, reverse=reverse)
                while queue:
                    yield queue[0].identifier
                    expansion = [self[i] for i in queue[0].successors(self._identifier)
                                 if filter(self[i])]
                    if sorting:
                        expansion.sort(key=key, reverse=reverse)
                    if mode is self.DEPTH:
                        queue = expansion + queue[1:]
                    elif mode is self.WIDTH:
                        queue = queue[1:] + expansion

            elif mode is self.ZIGZAG:
                stack_fw = []
                queue.reverse()
                stack = stack_bw = queue
                direction = False
                while stack:
                    expansion = [self[i] for i in stack[0].successors(self._identifier)
                                 if filter(self[i])]
                    yield stack.pop(0).identifier
                    if direction:
                        expansion.reverse()
                        stack_bw = expansion + stack_bw
                    else:
                        stack_fw = expansion + stack_fw
                    if not stack:
                        direction = not direction
                        stack = stack_fw if direction else stack_bw

            else:
                raise ValueError(
                    "Traversal mode '{}' is not supported".format(mode))

    def filter_nodes(self, func):
        return filter(func, self.all_nodes_itr())

    def get_node(self, nid):
        if nid is None or not self.contains(nid):
            return None
        return self._nodes[nid]

    def is_branch(self, nid):
        if nid is None:
            raise OSError("First parameter can't be None")
        if not self.contains(nid):
            raise NodeIDAbsentError("Node '%s' is not in the tree" % nid)

        try:
            fpointer = self[nid].successors(self._identifier)
        except KeyError:
            fpointer = []
        return fpointer

    def leaves(self, nid=None):
        leaves = []
        if nid is None:
            for node in self._nodes.values():
                if node.is_leaf(self._identifier):
                    leaves.append(node)
        else:
            for node in self.expand_tree(nid):
                if self[node].is_leaf(self._identifier):
                    leaves.append(self[node])
        return leaves

    def level(self, nid, filter=None):
        return len([n for n in self.rsearch(nid, filter)]) - 1

    def link_past_node(self, nid):
        if not self.contains(nid):
            raise NodeIDAbsentError("Node '%s' is not in the tree" % nid)
        if self.root == nid:
            raise LinkPastRootNodeError("Cannot link past the root node, "
                                        "delete it with remove_node()")
        parent = self[self[nid].predecessor(self._identifier)]
        for child in self[nid].successors(self._identifier):
            self[child].set_predecessor(parent.identifier, self._identifier)
        for id_ in self[nid].successors(self._identifier) or []:
            parent.update_successors(id_, tree_id=self._identifier)
        parent.update_successors(nid, mode=parent.DELETE, tree_id=self._identifier)
        del self._nodes[nid]

    def move_node(self, source, destination):
        if not self.contains(source) or not self.contains(destination):
            raise NodeIDAbsentError
        elif self.is_ancestor(source, destination):
            raise LoopError

        parent = self[source].predecessor(self._identifier)
        self.__update_fpointer(parent, source, self.node_class.DELETE)
        self.__update_fpointer(destination, source, self.node_class.ADD)
        self.__update_bpointer(source, destination)

    def is_ancestor(self, ancestor, grandchild):
        parent = self[grandchild].predecessor(self._identifier)
        child = grandchild
        while parent is not None:
            if parent == ancestor:
                return True
            else:
                child = self[child].predecessor(self._identifier)
                parent = self[child].predecessor(self._identifier)
        return False

    @property
    def nodes(self):
        return self._nodes

    def parent(self, nid):
        if not self.contains(nid):
            raise NodeIDAbsentError("Node '%s' is not in the tree" % nid)

        pid = self[nid].predecessor(self._identifier)
        if pid is None or not self.contains(pid):
            return None

        return self[pid]

    def merge(self, nid, new_tree, deep=False):
        if new_tree.root is None:
            return

        if nid is None:
            if self.root is None:
                new_tree_root = new_tree[new_tree.root]
                self.add_node(new_tree_root)
                nid = new_tree.root
            else:
                raise ValueError('Must define "nid" under which new tree is merged.')
        for child in new_tree.children(new_tree.root):
            self.paste(nid=nid, new_tree=new_tree.subtree(child.identifier), deep=deep)

    def paste(self, nid, new_tree, deep=False):
        assert isinstance(new_tree, Tree)

        if new_tree.root is None:
            return

        if nid is None:
            raise ValueError('Must define "nid" under which new tree is pasted.')

        if not self.contains(nid):
            raise NodeIDAbsentError("Node '%s' is not in the tree" % nid)

        set_joint = set(new_tree._nodes) & set(self._nodes)
        if set_joint:
            raise ValueError('Duplicated nodes %s exists.' % list(map(text, set_joint)))

        for cid, node in iteritems(new_tree.nodes):
            if deep:
                node = deepcopy(new_tree[node])
            self._nodes.update({cid: node})
            node.clone_pointers(new_tree.identifier, self._identifier)

        self.__update_bpointer(new_tree.root, nid)
        self.__update_fpointer(nid, new_tree.root, self.node_class.ADD)

    def paths_to_leaves(self):
        res = []

        for leaf in self.leaves():
            res.append([nid for nid in self.rsearch(leaf.identifier)][::-1])

        return res

    def remove_node(self, identifier):
        if not self.contains(identifier):
            raise NodeIDAbsentError("Node '%s' "
                                    "is not in the tree" % identifier)

        parent = self[identifier].predecessor(self._identifier)

        removed = list(self.expand_tree(identifier))

        for id_ in removed:
            if id_ == self.root:
                self.root = None
            self.__update_bpointer(id_, None)
            for cid in self[id_].successors(self._identifier) or []:
                self.__update_fpointer(id_, cid, self.node_class.DELETE)

        self.__update_fpointer(parent, identifier, self.node_class.DELETE)
        self.__update_bpointer(identifier, None)

        for id_ in removed:
            self.nodes.pop(id_)
        return len(removed)

    def remove_subtree(self, nid, identifier=None):
        st = self._clone(identifier)
        if nid is None:
            return st

        if not self.contains(nid):
            raise NodeIDAbsentError("Node '%s' is not in the tree" % nid)
        st.root = nid

        parent = self[nid].predecessor(self._identifier)

        removed = list(self.expand_tree(nid))
        for id_ in removed:
            if id_ == self.root:
                self.root = None
            st._nodes.update({id_: self._nodes.pop(id_)})
            st[id_].clone_pointers(self._identifier, st.identifier)
            st[id_].reset_pointers(self._identifier)
            if id_ == nid:
                st[id_].set_predecessor(None, st.identifier)
        self.__update_fpointer(parent, nid, self.node_class.DELETE)
        return st

    def rsearch(self, nid, filter=None):
        if nid is None:
            return

        if not self.contains(nid):
            raise NodeIDAbsentError("Node '%s' is not in the tree" % nid)

        filter = (lambda x: True) if (filter is None) else filter

        current = nid
        while current is not None:
            if filter(self[current]):
                yield current
            current = self[current].predecessor(self._identifier) if self.root != current else None

    def save2file(self, filename, nid=None, level=ROOT, idhidden=True,
                  filter=None, key=None, reverse=False, line_type='ascii-ex', data_property=None):

        def _write_line(line, f):
            f.write(line + b'\n')

        handler = lambda x: _write_line(x, open(filename, 'ab'))

        self.__print_backend(nid, level, idhidden, filter,
                             key, reverse, line_type, data_property, func=handler)

    def show(self, nid=None, level=ROOT, idhidden=True, filter=None,
             key=None, reverse=False, line_type='ascii-ex', data_property=None, stdout=True):
        self._reader = ""

        def write(line):
            self._reader += line.decode('utf-8') + "\n"

        try:
            self.__print_backend(nid, level, idhidden, filter,
                                 key, reverse, line_type, data_property, func=write)
        except NodeIDAbsentError:
            print('Tree is empty')

        if stdout:
            print(self._reader)
        else:
            return self._reader

    def siblings(self, nid):
        siblings = []

        if nid != self.root:
            pid = self[nid].predecessor(self._identifier)
            siblings = [self[i] for i in self[pid].successors(self._identifier) if i != nid]

        return siblings

    def size(self, level=None):
        if level is None:
            return len(self._nodes)
        else:
            try:
                level = int(level)
                return len([node for node in self.all_nodes_itr() if self.level(node.identifier) == level])
            except:
                raise TypeError(
                    "level should be an integer instead of '%s'" % type(level))

    def subtree(self, nid, identifier=None):
        st = self._clone(identifier)
        if nid is None:
            return st

        if not self.contains(nid):
            raise NodeIDAbsentError("Node '%s' is not in the tree" % nid)

        st.root = nid
        for node_n in self.expand_tree(nid):
            st._nodes.update({self[node_n].identifier: self[node_n]})
            st[node_n].clone_pointers(self._identifier, st.identifier)
            if node_n == nid:
                st[node_n].set_predecessor(None, st.identifier)
        return st

    def update_node(self, nid, **attrs):
        cn = self[nid]
        for attr, val in iteritems(attrs):
            if attr == 'identifier':
                cn = self._nodes.pop(nid)
                setattr(cn, 'identifier', val)
                self._nodes[val] = cn

                if cn.predecessor(self._identifier) is not None:
                    self[cn.predecessor(self._identifier)].update_successors(
                        nid, mode=self.node_class.REPLACE, replace=val,
                        tree_id=self._identifier
                    )

                for fp in cn.successors(self._identifier):
                    self[fp].set_predecessor(val, self._identifier)

                if self.root == nid:
                    self.root = val
            else:
                setattr(cn, attr, val)

    def to_dict(self, nid=None, key=None, sort=True, reverse=False, with_data=False):

        nid = self.root if (nid is None) else nid
        ntag = self[nid].tag
        tree_dict = {ntag: {"children": []}}
        if with_data:
            tree_dict[ntag]["data"] = self[nid].data

        if self[nid].expanded:
            queue = [self[i] for i in self[nid].successors(self._identifier)]
            key = (lambda x: x) if (key is None) else key
            if sort:
                queue.sort(key=key, reverse=reverse)

            for elem in queue:
                tree_dict[ntag]["children"].append(
                    self.to_dict(elem.identifier, with_data=with_data, sort=sort, reverse=reverse))
            if len(tree_dict[ntag]["children"]) == 0:
                tree_dict = self[nid].tag if not with_data else \
                    {ntag: {"data": self[nid].data}}
            return tree_dict

    def to_json(self, with_data=False, sort=True, reverse=False):
        return json.dumps(self.to_dict(with_data=with_data, sort=sort, reverse=reverse))

    def to_graphviz(self, filename=None, shape='circle', graph='digraph'):
        nodes, connections = [], []
        if self.nodes:

            for n in self.expand_tree(mode=self.WIDTH):
                nid = self[n].identifier
                state = '"{0}" [label="{1}", shape={2}]'.format(
                    nid, self[n].tag, shape)
                nodes.append(state)

                for c in self.children(nid):
                    cid = c.identifier
                    connections.append('"{0}" -> "{1}"'.format(nid, cid))

        is_plain_file = filename is not None
        if is_plain_file:
            f = codecs.open(filename, 'w', 'utf-8')
        else:
            f = StringIO()

        f.write(graph + ' tree {\n')
        for n in nodes:
            f.write('\t' + n + '\n')

        if len(connections) > 0:
            f.write('\n')

        for c in connections:
            f.write('\t' + c + '\n')

        f.write('}')

        if not is_plain_file:
            print(f.getvalue())

        f.close()
