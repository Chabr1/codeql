import ql
private import codeql_ql.ast.internal.AstNodes as AstNodes
private import codeql_ql.ast.internal.TreeSitter

private class ContainerOrModule extends TContainerOrModule {
  string getName() { none() }

  ContainerOrModule getEnclosing() { none() }

  string toString() { none() }

  predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    none()
  }

  /** Gets the kind of this file/module/folder. */
  string getKind() {
    this = TFile(_) and result = "file"
    or
    this = TModule(_) and result = "module"
    or
    this = TFolder(_) and result = "folder"
  }

  /** Gets the module for this imported module. */
  Module asModule() { this = TModule(result) }

  /** Gets the file for this file. */
  File asFile() { this = TFile(result) }
}

private class TFileOrModule = TFile or TModule;

/** A file or a module. */
class FileOrModule extends TFileOrModule, ContainerOrModule {
  /** Gets the file that contains this module/file. */
  File getFile() {
    result = this.asFile()
    or
    result = this.asModule().getLocation().getFile()
  }

  Type toType() {
    result.(FileType).getDeclaration().getLocation().getFile() = this.asFile()
    or
    result.(ModuleType).getDeclaration() = this.asModule()
  }
}

private class File_ extends FileOrModule, TFile {
  File f;

  File_() { this = TFile(f) }

  override ContainerOrModule getEnclosing() { result = TFolder(f.getParentContainer()) }

  override string getName() { result = f.getStem().replaceAll(" ", "_") }

  override string toString() { result = f.toString() }

  override predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    filepath = f.getAbsolutePath() and
    startline = 0 and
    startcolumn = 0 and
    endline = 0 and
    endcolumn = 0
  }
}

private class Folder_ extends ContainerOrModule, TFolder {
  Folder f;

  Folder_() { this = TFolder(f) }

  override ContainerOrModule getEnclosing() {
    result = TFolder(f.getParentContainer()) and
    // if this the the root, then we stop.
    not exists(f.getFile("qlpack.yml"))
  }

  override string getName() { result = f.getStem().replaceAll(" ", "_") }

  override string toString() { result = f.toString() }

  override predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    filepath = f.getAbsolutePath() and
    startline = 0 and
    startcolumn = 0 and
    endline = 0 and
    endcolumn = 0
  }

  /**
   * Gets the folder that this IPA type represents.
   */
  Folder getFolder() { result = f }
}

class Module_ extends FileOrModule, TModule {
  Module m;

  Module_() { this = TModule(m) }

  override ContainerOrModule getEnclosing() { result = getEnclosingModule(m) }

  override string getName() { result = m.getName() }

  override string toString() { result = m.toString() }

  override predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    m.getLocation().hasLocationInfo(filepath, startline, startcolumn, endline, endcolumn)
  }
}

private predicate resolveQualifiedName(Import imp, ContainerOrModule m, int i) {
  not m = TFile(any(File f | f.getExtension() = "ql")) and
  exists(string q | q = imp.getQualifiedName(i) |
    i = 0 and
    (
      exists(Container c, Container parent |
        // should ideally look at `qlpack.yml` files
        parent = pragma[only_bind_out](imp.getLocation()).getFile().getParentContainer+() and
        exists(YAML::QLPack pack |
          pack.getFile().getParentContainer() = parent and
          c.getParentContainer() = pack.getADependency*().getFile().getParentContainer()
        ) and
        q = m.getName()
      |
        m = TFile(c)
        or
        m = TFolder(c)
      )
      or
      q = imp.getQualifiedName(i) and
      exists(ContainerOrModule container | container = getEnclosingModule(imp).getEnclosing+() |
        definesModule(container, q, m, _) and
        (
          exists(container.(Folder_).getFolder().getFile("qlpack.yml")) or
          container.(Folder_).getFolder() =
            pragma[only_bind_out](imp.getLocation()).getFile().getParentContainer() or
          not container instanceof Folder_
        )
      )
      or
      definesModule(getEnclosingModule(imp), q, m, _)
    )
    or
    exists(Folder_ mid |
      resolveQualifiedName(imp, mid, i - 1) and
      m.getEnclosing() = mid and
      q = m.getName()
    )
  )
}

private predicate resolveSelectionName(Import imp, ContainerOrModule m, int i) {
  (m.(File_).getFile().getExtension() = "qll" or not m instanceof File_) and
  exists(int last |
    resolveQualifiedName(imp, m, last) and
    last = count(int j | exists(imp.getQualifiedName(j))) - 1
  ) and
  not m instanceof Folder_ and
  i = -1
  or
  exists(ContainerOrModule mid |
    resolveSelectionName(imp, mid, i - 1) and
    definesModule(mid, imp.getSelectionName(i), m, true)
  )
}

cached
private module Cached {
  private AstNode parent(AstNode n) {
    result = n.getParent() and
    not n instanceof Module
  }

  private Module getEnclosingModule0(AstNode n) { result = parent*(n.getParent()) }

  cached
  ContainerOrModule getEnclosingModule(AstNode n) {
    result = TModule(getEnclosingModule0(n))
    or
    not exists(getEnclosingModule0(n)) and
    result = TFile(n.getLocation().getFile())
  }

  cached
  module NewType {
    cached
    newtype TContainerOrModule =
      TFile(File f) or
      TFolder(Folder f) or
      TModule(Module m)
  }

  /** Holds if import statement `imp` resolves to `m`. */
  cached
  predicate resolve(Import imp, FileOrModule m) {
    exists(int last |
      resolveSelectionName(imp, m, last) and
      last = count(int j | exists(imp.getSelectionName(j))) - 1
    )
  }

  /** Holds if module expression `me` resolves to `m`. */
  cached
  predicate resolveModuleRef(TypeRef me, FileOrModule m) {
    not m = TFile(any(File f | f.getExtension() = "ql")) and
    not exists(me.(ModuleExpr).getQualifier()) and
    exists(ContainerOrModule enclosing, string name | resolveModuleRefHelper(me, enclosing, name) |
      definesModule(enclosing, name, m, _)
    )
    or
    exists(FileOrModule mid |
      resolveModuleRef(me.(ModuleExpr).getQualifier(), mid) and
      definesModule(mid, me.(ModuleExpr).getName(), m, true)
    )
  }

  pragma[noinline]
  private predicate resolveModuleRefHelper(TypeRef me, ContainerOrModule enclosing, string name) {
    enclosing = getEnclosingModule(me).getEnclosing*() and
    name = [me.(ModuleExpr).getName(), me.(TypeExpr).getClassName()]
  }
}

import Cached
private import NewType

boolean getPublicBool(AstNode n) {
  if
    n.(ModuleMember).isPrivate() or
    n.(NewTypeBranch).getNewType().isPrivate() or
    n.(Module).isPrivate()
  then result = false
  else result = true
}

/**
 * Holds if `container` defines module `m` with name `name`.
 *
 * `m` may be defined either directly or through `import`s.
 */
private predicate definesModule(
  ContainerOrModule container, string name, ContainerOrModule m, boolean public
) {
  container = m.getEnclosing() and
  name = m.getName() and
  (
    (m instanceof File_ or m instanceof Folder_) and
    public = true
    or
    m = TModule(any(Module mod | public = getPublicBool(mod)))
  )
  or
  // signature module in a paramertized module
  exists(Module mod, SignatureExpr sig, TypeExpr ty, int i |
    mod = container.asModule() and
    mod.hasParameter(i, name, sig) and
    public = false and
    ty = sig.asType()
  |
    // resolve to the signature module
    m = ty.getResolvedModule()
    or
    // resolve to the arguments of the instantiated module
    exists(ModuleExpr inst | inst.getResolvedModule().asModule() = mod |
      m = inst.getArgument(i).asType().getResolvedModule()
    )
  )
  or
  // import X
  exists(Import imp, ContainerOrModule m0 |
    container = getEnclosingModule(imp) and
    resolve(imp, m0) and
    not exists(imp.importedAs()) and
    definesModule(m0, name, m, true) and
    public = getPublicBool(imp)
  )
  or
  // import X as Y
  exists(Import imp |
    container = getEnclosingModule(imp) and
    name = imp.importedAs() and
    resolve(imp, m) and
    public = getPublicBool(imp)
  )
  or
  // module X = Y
  exists(Module alias |
    container = getEnclosingModule(alias) and
    name = alias.getName() and
    resolveModuleRef(alias.getAlias(), m) and
    public = getPublicBool(alias)
  )
}

module ModConsistency {
  query predicate noResolve(Import imp) {
    not resolve(imp, _) and
    not imp.getLocation()
        .getFile()
        .getAbsolutePath()
        .regexpMatch(".*/(test|examples|ql-training|recorded-call-graph-metrics)/.*")
  }

  query predicate multipleResolve(Import imp, int c, ContainerOrModule m) {
    c = strictcount(ContainerOrModule m0 | resolve(imp, m0)) and
    c > 1 and
    resolve(imp, m) and
    not imp.getLocation()
        .getFile()
        .getAbsolutePath()
        .regexpMatch(".*/(test|examples|ql-training|recorded-call-graph-metrics)/.*")
  }

  // This can happen with parameterized modules.
  /*
   * query predicate multipleResolveModuleRef(ModuleExpr me, int c, ContainerOrModule m) {
   *    c = strictcount(ContainerOrModule m0 | resolveModuleRef(me, m0)) and
   *    c > 1 and
   *    resolveModuleRef(me, m)
   *  }
   */

  query predicate noName(Module mod) { not exists(mod.getName()) }

  query predicate nonUniqueName(Module mod) { count(mod.getName()) >= 2 }
}
