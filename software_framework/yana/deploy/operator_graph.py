from typing import List, Optional, Callable, Union

import nir


TRANSPARENT_OPS = [nir.Flatten]
UNSUPPORTED_OPS = [
    nir.Conv1d,
    nir.Conv2d,
    nir.Delay,
    nir.NIRGraph,
    nir.Scale,
    nir.CubaLIF,
    nir.IF,
]


class UnsupportedNodeError(Exception):
    def __init__(self, node: nir.NIRNode):
        super().__init__(f"Unsupported NIR node type: {type(node).__name__}")


class Operator():
    name: str
    nir_node: nir.NIRNode
    pre_ops: List['Operator']
    post_ops: List['Operator']

    def __init__(self, name: str, nir_node: nir.NIRNode):
        self.name = name
        self.nir_node = nir_node
        self.pre_ops = []
        self.post_ops = []

    def add_pre_node(self, pre_op: 'Operator'):
        self.pre_ops.append(pre_op)

    def add_post_node(self, post_op: 'Operator'):
        self.post_ops.append(post_op)

    def __repr__(self):
        return f"Operator(name={self.name}, nir_node={self.nir_node}, pre_ops={[op.name for op in self.pre_ops]}, post_ops={[op.name for op in self.post_ops]})"

    def __str__(self):
        pre_ops_names = [op.name for op in self.pre_ops]
        post_ops_names = [op.name for op in self.post_ops]
        return (f"Operator: {self.name}\n"
                f"  Type: {type(self.nir_node).__name__}\n"
                f"  Pre-operators: {pre_ops_names}\n"
                f"  Post-operators: {post_ops_names}")

    def __hash__(self):
        return hash(self.name)


class OperatorGraph():
    input_ops: List[Operator]
    output_ops: List[Operator]

    def __init__(self, nir_graph: nir.NIRGraph):
        self.input_ops = [Operator(key, node) for key, node in nir_graph.inputs.items()]

        # Traverse NIR graph to extract operators
        ready = [edge for edge in nir_graph.edges if edge[0] in nir_graph.inputs.keys()]
        seen = set([edge[0] for edge in ready])

        while len(ready) > 0:
            pre_key, post_key = ready.pop()
            post_node = nir_graph.nodes[post_key]

            pre_op = self[pre_key]
            post_op = self[post_key]
            if post_op is None: # First time post_key has been traversed
                post_op = Operator(post_key, post_node)
                seen.add(post_key)
                ready += [e for e in nir_graph.edges if e[0] == post_key]

            assert pre_op is not None
            pre_op.add_post_node(post_op)
            post_op.add_pre_node(pre_op)

        # Check for unsupported operators and remove transparent operators 
        for op in self:
            if type(op.nir_node) in UNSUPPORTED_OPS:
                raise UnsupportedNodeError(op.nir_node)
            elif type(op.nir_node) in TRANSPARENT_OPS:
                self.remove(op)

        # Add output operators
        self.output_ops = [op for op in self if len(op.post_ops) == 0]
        assert nir_graph.outputs == {op.name: op.nir_node for op in self.output_ops}, "NIR Graph broken. Output operators do not match output nodes."

    def __contains__(self, operator: Operator) -> bool:
        for op in self:
            if operator.name == op.name:
                return True
        return False

    def __getitem__(self, name: str) -> Optional[Operator]:
        for op in self:
            if op.name == name:
                return op
        return None

    def __str__(self) -> str:
        result = []

        for op in self:
            result.append(f"Operator: {op.name}, Type: {type(op.nir_node).__name__}")
            if len(op.pre_ops) > 0:
                result.append(f"  Pre-operators: {[pre_op.name for pre_op in op.pre_ops]}")
            if len(op.post_ops) > 0:
                result.append(f"  Post-operators: {[post_op.name for post_op in op.post_ops]}")

        return "\n".join(result)

    def __iter__(self):
        return self.iter_from(self.input_ops[:])

    def __reversed__(self):
        return self.iter_reversed_from(self.output_ops[:])

    def iter_from(self, start_op: Union[Operator, List[Operator]]):
        ready = [start_op] if isinstance(start_op, Operator) else start_op
        seen = set()
        while ready:
            op = ready.pop()
            if op.name in seen:
                continue
            seen.add(op.name)
            yield op
            ready.extend(op.post_ops)

    def iter_reversed_from(self, end_op: Union[Operator, List[Operator]]):
        ready = [end_op] if isinstance(end_op, Operator) else end_op
        seen = set()
        while ready:
            op = ready.pop()
            if op.name in seen:
                continue
            seen.add(op.name)
            yield op
            ready.extend(op.pre_ops)

    def remove(self, operator: Operator):
        for op in self:
            if op == operator:
                assert len(op.pre_ops) == 1, "Only allowed to call 'remove' on operators with single predecessor!"
                assert len(op.post_ops) == 1, "Only allowed to call 'remove' on operators with single successor!"
                # Connect predecessor
                op.pre_ops[0].post_ops.remove(op)
                op.pre_ops[0].post_ops.append(op.post_ops[0])
                # Connect successor
                op.post_ops[0].pre_ops.remove(op)
                op.post_ops[0].pre_ops.append(op.pre_ops[0])

    def parse_sequences(self, match_fn: Callable[[List['Operator']], bool], strict: bool = True):
        traversed_edges = []
        for op in self.input_ops:
            stack = [[op]]
            path = []
            while stack:
                path = stack.pop()
                last_op = path[-1]
                if match_fn(path):
                    path.clear()
                for next_op in last_op.post_ops:
                    edge = (last_op.name, next_op.name)
                    if edge not in traversed_edges:
                        new_path = path + [next_op]
                        traversed_edges.append(edge)
                        stack.append((new_path))
            if strict:
                assert len(path) == 0, f"Unvalidated sequence: {[type(op.nir_node).__name__ for op in path]}"
        return traversed_edges
