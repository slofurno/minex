defmodule Minesweepers.Bot do
  use GenServer
  alias Minesweepers.RevealEvent
  alias Minesweepers.Game
  alias Minesweepers.Game.Board

  @first_click {20,20}
  @initial_moves {[], []}

  def start_link(game) do
    GenServer.start_link(__MODULE__, [game], name: via_tuple(Utils.uuid))
  end

  def init([game]) do
    player = Utils.uuid
    ref = Game.whereis(game) |> Process.monitor
    %{rows: rows, cols: cols, squares: squares} = Game.get_initial_state(game)
    Game.subscribe(game)
    Game.set_name(game, player, "robot player")
    schedule_next_move()

    {:ok, %{id: game, player: player, squares: rebuild_game(squares), ref: ref,
      rows: rows, cols: cols, moves: @initial_moves, start: @first_click}}
  end

  defp schedule_next_move do
    :erlang.send_after(300, self(), :move)
  end

  def handle_call({:state}, _from, state), do: {:reply, state, state}

  def handle_call(:move, _from, state) do
    moves = find_easy_moves(state)
    {:reply, moves, state}
  end

  def handle_call({:click, pos}, _front, state) do
    {:reply, :ok, %{state| start: pos}}
  end

  defp rebuild_game(squares) do
    List.foldl(squares, %{}, fn square, map -> Map.put(map, {square.row, square.col}, square) end)
  end

  def handle_info({:DOWN, ref1, :process, _pid, _reason}, %{ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:move, %{moves: {flag, click}, id: game, player: player} = state) do
    cond do
      Enum.count(flag) > 0 ->
        [pos |rest] = flag
        Game.player_click(%Minesweepers.ClickEvent{game: game, player: player, pos: pos, right: true})
        schedule_next_move()
        {:noreply, %{state| moves: {rest, click}}}

      Enum.count(click) > 0 ->
        [pos |rest] = click
        Game.player_click(%Minesweepers.ClickEvent{game: game, player: player, pos: pos, right: false})
        schedule_next_move()
        {:noreply, %{state| moves: {flag, rest}}}
      true ->
        {flag, click} = find_easy_moves(state)
        if Enum.count(flag) + Enum.count(click) > 0 do
          schedule_next_move()
          {:noreply, %{state| moves: {flag, click}}}

        else
          %{rows: rows, cols: cols} = state
          x = :rand.uniform(rows) - 1
          y = :rand.uniform(cols) - 1
          click = %Minesweepers.ClickEvent{game: game, player: player, pos: {x,y}}
          Game.player_click(click)

          schedule_next_move()
          {:noreply, %{state| start: {x, y}}}
        end

    end
  end

  def handle_info({:game_event, %RevealEvent{squares: changed, player: event_player}}, %{player: player} = state) when event_player == player do
    #IO.puts "#{Enum.count(changed)} squares update"
    squares = List.foldl(changed, state.squares, fn x, map -> Map.put(map, {x.row, x.col}, x) end)
    {:noreply, %{state| squares: squares} }
  end

  def handle_info(n, state) do
    {:noreply, state}
  end

  defp find_easy_moves(%{squares: squares, moves: moves, rows: rows, cols: cols, start: start} = state) do
    front = find_front(state, start)
    |> Map.to_list
    |> List.foldl([], fn
      {k,false}, xs -> xs
      {k,true}, xs -> [k| xs]
    end)

    options = List.foldl(front, [], fn pos, xs ->
      neighbors = Board.neighbors(state, pos)
      |> Enum.map(fn pos -> {pos, squares[pos]} end)

      open = Enum.filter(neighbors, fn {pos, square} -> square == nil end)
      bombs = Enum.filter(neighbors, fn
        {_, nil} -> false
        {_, %{s: :bomb}} -> true
        {_, %{s: :flagged}} -> true
        _ -> false
      end) |> Enum.count

      neighbors = squares[pos].n
      [{pos, neighbors, bombs, open} |xs]
    end)

    flag = Enum.filter(options, fn {pos, neighbors, bombs, open} ->
      neighbors - bombs == Enum.count(open)
    end)
    |> Enum.map(fn {_pos, _n, _bombs, open} -> open end)
    |> List.flatten
    |> Enum.map(fn {pos, _} -> pos end)


    click = Enum.filter(options, fn {pos, neighbors, bombs, open} ->
      neighbors == bombs
    end)
    |> Enum.map(fn {_pos, _n, _bombs, open} -> open end)
    |> List.flatten
    |> Enum.map(fn {pos, _} -> pos end)

    {flag, click}
  end

  defp find_front(state, pos, seen \\ %{})

  defp find_front(%{squares: squares, rows: rows, cols: cols} = state, pos, seen) do
    cond do
      Map.has_key?(seen, pos) -> seen

      squares[pos] == nil -> Map.put(seen, pos, false)

      true ->
        has_neighbors = squares[pos].n > 0
        seen = Map.put(seen, pos, has_neighbors)

        Board.neighbors(state, pos)
        |> List.foldl(seen, fn c, a -> find_front(state, c, a) end)
    end
  end

  def via_tuple(bot) do
    {:via, :gproc, {:n, :l, {:bot, bot}}}
  end

end
