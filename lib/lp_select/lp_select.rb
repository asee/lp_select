
# -----------------------------------------------
#  
#  This class relies on the lpsolve library hooks, and 
#  serves as a specialized interface for solving the
#  NSF selection problem.  It uses binary variables 
#  names with the applicant IDs to determine who is 
#  selected.  There is a paper written on it as well
#  as assorted documentation in the trunk folder of this
#  repository.
# -----------------------------------------------

include LPSolve

class LPSelect
  
  attr_reader :vars, :lp, :model_name, :results, :objective, :constraints, :objective_row
  CONSTRAINT_ROW = {:name => "", :vars => [], :op => nil, :target => nil} #our own little format
  
  
  # Create a new selection equation, either by passing a list of variables
  # corresponding to applicants, or by passing a YAML file or string that
  # represents an equation serialized by this same model.
  #
  # Optionally it can load a file from disk in the lp format and solve it, 
  # although many of the utilities for inspecting the equation and serializing
  # it will be non-functional
  def initialize(opts = {})
    
    # The objective is the overall equation to solve, in our case, the minimum
    # sum of each applicants rank
    @objective_row = {:direction => "min", :weights => {} }
    @constraints = [] #This will be filled with dups of CONSTRAINT_ROW
    @var_struct = nil
    
    if opts[:filename] && File::exists?(opts[:filename])
      load_from_file(opts[:filename])
    elsif opts[:vars]
      raise "Invalid option, vars must be an array" unless opts[:vars].is_a? Array
      create_new(opts[:vars])
    elsif opts[:yaml]
      load_from_yaml(opts[:yaml])
    else
      raise "Must pass :filename, :yaml, or :vars"
    end
    
    @model_name = Time.now().strftime('%Y%m%d%H%M')
    LPSolve::set_lp_name(@lp, @model_name)
    
    LPSolve::set_verbose(@lp, LPSolve::SEVERE )
  end
  
  def create_new(varnames)
    self.vars = varnames
    cols = @vars.length
    @lp = LPSolve::make_lp(0, cols) 
    1.upto(cols) do |cnum| 
      cname = varnames[cnum-1] #For every column get the column name and index (NOT zero indexed)
      LPSolve::set_binary(@lp, cnum, 1) #Define the column to be binary
      LPSolve::set_col_name(@lp, cnum, cname.to_s) #Set the name to what we passed
    end    
  end
  
  def load_from_file(filename)
    @lp = LPSolve::read_LP(filename, LPSolve::SEVERE, "")
    
    loc_lp = LPSolve::copy_lp(@lp) #We make a copy to avoid advancing internal pointers.
    existing_vars = []
    1.upto(get_Ncolumns) do |col|
      existing_vars << LPSolve::get_origcol_name(loc_lp, col).to_s
    end
    self.vars = existing_vars
  end
  
  # Weights should be a hash with variable names as keys, and
  # individual multipliers as the values.  Eg, { "v1" => 10 }
  # would return a row like +10 v1
  def set_objective(weights, direction = :min)
    weights = weights.inject({}) do |options, (key, value)|
      options[key.to_sym] = value
      options
    end
    
    obj_fn = build_empty_var_struct
    obj_fn["zero_index"] = 1.0
    @vars.each do |var|
      weight = weights[var] || 0.0
      obj_fn[var.to_s] = weight
    end
    
    LPSolve::set_obj_fn(@lp, obj_fn)
    
    if direction == :max
      LPSolve::set_maxim(@lp)
    else
      LPSolve::set_minim(@lp)
    end
    
    @objective_row = {:direction => direction, :weights => weights }
    
  end
  
  def solve
    
    #Important step.
    solution = LPSolve::solve(@lp) 

    if solution == LPSolve::OPTIMAL || LPSolve::SUBOPTIMAL
      #--------------------
      #  Get the values
      #--------------------
      retvals = build_empty_var_struct
    
      err = LPSolve::get_variables(@lp, retvals)
    
      @results = {}
      @vars.each do |c|
        @results[c] = retvals[c.to_s].to_f
      end
    
      #--------------------
      #  Set the objective (eg, final sum)
      #--------------------
      @objective = LPSolve::get_objective(@lp)
    end
    return solution
    
  end
  
  
  # This piece is what's used to ensure that the function selects the right amounts from
  # the right categories.  For example, to select at least one applicant from Maine,
  # we could add a constraint saying that the sum of all applicant variables
  # representing the applicants from Maine must be greater than or equal to 1.
  def add_constraint(rowdef = CONSTRAINT_ROW)
    
    raise "You must specify at least one variable to add a constraint" if rowdef[:vars].length == 0
    raise "You must specify an operation" if rowdef[:op].nil?
    raise "You must specify a target (ie, right hand side)" if rowdef[:target].nil?  
    raise "Target must be a number" unless rowdef[:target].is_a?(Float) || rowdef[:target].is_a?(Integer)
    
    varnames = rowdef[:vars].map! {|v| v.to_sym}
    
    #The API expects a 1 indexed array, so start with an empty item in row_constraints[0]
    row_constraints = build_empty_var_struct
    row_constraints["zero_index"] = 0.0
    @vars.each do |v|
      # Since we're only interested in binary columns, putting in a 1 or a zero is sufficient
      # to either add them to the constraint or not
      row_constraints[v.to_s] =  (varnames.include?(v) ? 1.0 : 0.0)
    end
    
    LPSolve::add_constraint(@lp, row_constraints, rowdef[:op], rowdef[:target].to_f)

    # Every row has a name, and it's helpful if it suggests something about the constraint,
    # eg maine or minorities
    if rowdef[:name] == ""
      rowdef[:name] = "R#{@constraints.length+1}"
    end
    @constraints << rowdef
    LPSolve::set_row_name(@lp, @constraints.length, rowdef[:name])
  end
  
  def to_file(filename)
    loc_lp = LPSolve::copy_lp(@lp)
    valid = LPSolve::write_lp(loc_lp, filename)
    raise "Could not write to #{filename}" unless valid
  end
  
  def to_yaml
    @complete = {}
    @complete["vars"] = @vars
    @complete["model_name"] = @model_name
    @complete["constraints"] = @constraints
    @complete["objective"] = @objective_row unless @objective_row[:weights].empty?
    @complete.to_yaml
  end
  
  def load_from_yaml(yaml)
    @complete = YAML::load(yaml)
    raise "could not load from yaml" unless @complete
    create_new(@complete["vars"])
    LPSolve::set_lp_name(@lp, @complete["model_name"])
    @complete["constraints"].each do |c|
      add_constraint(c)
    end
    
    if @complete['objective']
      set_objective(@complete['objective'][:weights], @complete['objective'][:direction])
    end
  end
  
  def to_lp_format
    lp_text = "/* #{@model_name} */\n\n"
    
    lp_text << "/* Objective function */\n"
    lp_text << "#{@objective_row[:direction]}:"
    weights = @objective_row[:weights]
    weights.keys.sort_by{|s| s.to_s}.map{|key| [key, weights[key]] }.each do |var,constant|
      sign = constant > 0 ? "+" : "-"
      if constant.abs == 1
        lp_text << " #{sign}#{var}"
      else
        lp_text << " #{sign}#{constant} #{var}"
      end
    end
    lp_text << ";\n\n"
    
    lp_text << "/* Constraints */\n"
    @constraints.each do |row|
      row_vars = row[:vars].map{|x| "+#{x}"}.sort.join(" ")
      row_op = LPSolve.op_to_s(row[:op])
      lp_text << "#{row[:name]}: #{row_vars} #{row_op} #{row[:target]}; \n\n"
    end
    
    lp_text << "\n/* Varible Bounds */\n"
    @vars.each do |v|
      lp_text << "#{v} <= 1;\n"
    end

    lp_text << "\n/* Variable Definitions */\n"
    lp_text << "int #{@vars.join(", ")};"
    return lp_text
  end
  
  private 
  
    def build_empty_var_struct
      var_struct = Fiddle::CStructEntity.malloc([Fiddle::SIZEOF_DOUBLE] * (@vars.length+1))
      var_struct.assign_names(["zero_index"] + @vars.collect(&:to_s))
      var_struct
    end
  
    def vars=(new_vars)
      @vars = new_vars.collect(&:to_sym)
    end
  
    def get_Ncolumns
      @n_columns ||= LPSolve::get_Ncolumns(@lp)
    end
end
